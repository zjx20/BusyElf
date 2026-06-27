import Foundation

enum TaskVerb {
    case start, update, wait, end
}

/// 路径 → 动词 → 调 TaskStore。休眠逻辑只依赖路径 + `id`,与 body 其它字段解耦。
///
/// 两套入口,共用同一套 4 动词:
///  - `/v1/task/*`:**agent 中立**通用协议,body 已是中立字段(任何 agent 都可接)。
///  - `/claude/hooks`:**内建 Claude 适配器**,直接吃 Claude Code hook 的原始 payload
///    (`type: "http"`,免 jq+curl)。Claude 专属知识全在 [ClaudeHookEvent] 里,核心仍中立。
struct Router {
    let store: TaskStore

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

        guard isPost else { return Self.okBody }
        guard let verb = Self.verb(for: path) else { return Self.okBody }
        guard let event = TaskEvent.parse(body),
              let id = event.id, !id.isEmpty else { return Self.okBody }

        switch verb {
        case .start:
            store.start(id: id, name: event.name, agent: event.agent, cwd: event.cwd)
        case .update:
            store.update(id: id, tool: event.tool, detail: event.detail,
                         reply: event.reply, agent: event.agent, cwd: event.cwd)
        case .wait:
            store.wait(id: id, message: event.message)
        case .end:
            store.end(id: id)
        }
        return Self.okBody
    }

    /// 把一条 Claude hook 原始 payload 翻成中立动作并落到 TaskStore。无 id 则忽略。
    private func routeClaude(body: Data) {
        guard let hook = ClaudeHookEvent.parse(body),
              let id = hook.id, !id.isEmpty else { return }
        let agent = ClaudeHookEvent.agentLabel
        switch hook.action {
        case .start(let name):
            store.start(id: id, name: name, agent: agent, cwd: hook.cwd)
        case .update(let tool, let detail):
            store.update(id: id, tool: tool, detail: detail, reply: nil, agent: agent, cwd: hook.cwd)
        case .wait(let message):
            store.wait(id: id, message: message)
        case .end:
            store.end(id: id)
        case .ignore:
            break
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
        case "/v1/task/end":    return .end
        default:                return nil
        }
    }
}
