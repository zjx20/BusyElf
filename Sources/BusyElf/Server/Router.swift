import Foundation

enum TaskVerb {
    case start, update, wait, done, fail, remove
}

/// 路径 → 动词 → 调 TaskStore。休眠逻辑只依赖路径 + `id`,与 body 其它字段解耦。
///
/// 两套入口,共用同一套中立动词:
///  - `/v1/task/*`:**agent 中立**通用协议,body 已是中立字段(任何 agent 都可接)。
///  - `/claude/hooks`:**内建 Claude 适配器**,直接吃 Claude Code hook 的原始 payload
///    (`type: "http"`,免 jq+curl)。Claude 专属知识全在 [ClaudeHookEvent] 里,核心仍中立。
struct Router {
    let store: TaskStore

    /// 调试/观测端点是否开启。默认关闭(生产不暴露内部状态);设 `BUSYELF_DEBUG=1` 才开,供测试用。
    static let debugEnabled = ProcessInfo.processInfo.environment["BUSYELF_DEBUG"] == "1"

    /// 由服务器在解析出一条完整 HTTP 请求后调用。返回应回给客户端的响应 body。
    /// 非 POST / 未知路径 / 无 id 一律静默忽略(仍回 200,不阻塞调用方)。
    func route(method: String, path: String, body: Data) -> String {
        let path = Self.stripQuery(path)
        let isPost = method.uppercased() == "POST"

        // 内建 Claude 适配器:**始终回空 body**(无论方法),让 `/claude/hooks` 对 Claude 永远是无操作。
        // Claude 的 HTTP hook 把"2xx + 空体"视为无操作(等同退出码 0 无输出)——BusyElf 是纯被动观察者,
        // 绝不干预 Claude 的流程。仅 POST 才真正落库(Claude 也只会 POST);其它方法只回空体、不动状态。
        if path == Self.claudeHookPath {
            if isPost { routeClaude(body: body) }
            return ""
        }

        // 调试/观测端点(仅 BUSYELF_DEBUG=1):读内部状态 + 测试用的 reset / 模拟 popover 开关。
        if Self.debugEnabled, path.hasPrefix("/debug/") {
            return routeDebug(path: path, isPost: isPost, body: body)
        }

        guard isPost else { return Self.okBody }
        guard let verb = Self.verb(for: path) else { return Self.okBody }
        guard let event = TaskEvent.parse(body),
              let id = event.id, !id.isEmpty else { return Self.okBody }

        switch verb {
        case .start:
            store.start(id: id, parentId: event.parentId, name: event.name,
                        prompt: event.prompt, agent: event.agent, cwd: event.cwd)
        case .update:
            store.update(id: id, parentId: event.parentId, name: event.name,
                         tool: event.tool, detail: event.toolInput ?? event.detail,
                         reply: event.reply, replyAppend: event.replyAppend ?? false,
                         toolComplete: event.toolComplete ?? false,
                         toolFailed: event.toolFailed ?? false, toolError: event.toolError,
                         agent: event.agent, cwd: event.cwd)
        case .wait:
            store.wait(id: id, message: event.message, parentId: event.parentId,
                       name: event.name, agent: event.agent, cwd: event.cwd)
        case .done:
            store.done(id: id, reply: event.reply)
        case .fail:
            store.fail(id: id, parentId: event.parentId, name: event.name,
                       errorKind: event.errorKind, errorDetail: event.errorDetail,
                       reply: event.reply, agent: event.agent, cwd: event.cwd)
        case .remove:
            store.remove(id: id)
        }
        return Self.okBody
    }

    /// 把一条 Claude hook 原始 payload 翻成中立动作并落到 TaskStore。无 id 则忽略。
    private func routeClaude(body: Data) {
        // translate 有状态(子任务输入关联 + 后台任务差集),**每事件只调一次**;日志与落库共用同一结果,不可二次解析。
        // 多数事件翻成一个动作;父会话 Stop/SessionEnd 可能翻成多个(父 done + 各后台子项 update/done)。
        let hooks = ClaudeHookEvent.translate(body)
        // 调试插桩(仅 BUSYELF_DEBUG=1):打印原始 body + 解析出的动作序列(含折叠 id),看清"事件流 → 动作"映射。
        // NSLog 自带毫秒时间戳;生产环境(debugEnabled=false)一行不打。
        if Self.debugEnabled {
            let raw = String(decoding: body, as: UTF8.self)
            let shown = raw.count > 1200 ? String(raw.prefix(1200)) + "…(\(raw.count)B)" : raw
            if hooks.isEmpty {
                NSLog("[busyelf hook] action=NONE(非JSON对象或忽略) ← %@", shown)
            } else {
                let actions = hooks.map { "\(String(describing: $0.action))@\($0.id ?? "nil")" }.joined(separator: " | ")
                NSLog("[busyelf hook] actions=[%@] ← %@", actions, shown)
            }
        }
        let agent = ClaudeHookEvent.agentLabel
        for hook in hooks {
            guard let id = hook.id, !id.isEmpty else { continue }
            switch hook.action {
            case .start(let prompt):
                store.start(id: id, parentId: hook.parentId, name: hook.name,
                            prompt: prompt, agent: agent, cwd: hook.cwd)
            case .update(let tool, let detail, let reply, let replyAppend, let toolComplete, let toolFailed, let toolError):
                store.update(id: id, parentId: hook.parentId, name: hook.name,
                             tool: tool, detail: detail, reply: reply, replyAppend: replyAppend,
                             toolComplete: toolComplete, toolFailed: toolFailed, toolError: toolError,
                             agent: agent, cwd: hook.cwd)
            case .wait(let message):
                store.wait(id: id, message: message, parentId: hook.parentId,
                           name: hook.name, agent: agent, cwd: hook.cwd)
            case .done(let reply):
                store.done(id: id, reply: reply)
            case .fail(let kind, let detail, let reply):
                store.fail(id: id, parentId: hook.parentId, name: hook.name,
                           errorKind: kind, errorDetail: detail, reply: reply,
                           agent: agent, cwd: hook.cwd)
            case .enrich(let prompt):
                store.enrichPrompt(id: id, prompt: prompt)
            case .ignore:
                break
            }
        }
    }

    /// 调试/观测端点(仅 BUSYELF_DEBUG=1 时可达)。读只读状态 + 测试辅助。
    private func routeDebug(path: String, isPost: Bool, body: Data) -> String {
        switch path {
        case "/debug/state":            // GET:内部状态 JSON(写后读屏障,测试无需 sleep)
            return store.debugStateJSON()
        case "/debug/reset":            // POST:清空所有任务(测试隔离)
            if isPost { store.removeAll() }
            return Self.okBody
        case "/debug/seen":             // POST:模拟"打开 popover" → 标记终态 seen(清角标)
            if isPost { store.markTerminalSeen() }
            return Self.okBody
        case "/debug/purge":            // POST:模拟"关闭 popover" → 清理已 seen 终态
            if isPost { store.purgeSeenTerminal() }
            return Self.okBody
        case "/debug/timeout":          // POST body=秒数:设无活动超时并立即重排看门狗(测试看门狗放行用)
            if isPost, let s = String(data: body, encoding: .utf8),
               let secs = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                store.setInactivityTimeout(secs)
            }
            return Self.okBody
        default:
            return Self.okBody
        }
    }

    // MARK: - 路径

    static let claudeHookPath = "/claude/hooks"
    static let okBody = "{\"ok\":true}"

    /// 去掉 `?query` 串。
    static func stripQuery(_ rawPath: String) -> String {
        rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
    }

    /// 精确匹配 `/v1/task/{verb}`(传入路径应已去 query)。
    static func verb(for path: String) -> TaskVerb? {
        switch path {
        case "/v1/task/start":  return .start
        case "/v1/task/update": return .update
        case "/v1/task/wait":   return .wait
        case "/v1/task/done":   return .done
        case "/v1/task/fail":   return .fail
        case "/v1/task/remove": return .remove
        default:                return nil
        }
    }
}
