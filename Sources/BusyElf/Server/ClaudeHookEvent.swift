import Foundation

/// Claude Code hook 事件 → 中立动作的**内建适配器**。
///
/// Claude Code 的 HTTP hook(`type: "http"`)会把每个 hook 事件的原始 JSON 作为 POST body
/// 直接发到 `/claude/hooks`,无需用户在 hook 配置里写 `jq` + `curl`。本类型把这份原始 payload
/// 解析成 BusyElf 中立协议里的一个动作(start/update/wait/end/ignore)。
///
/// **为什么单独一个文件**:这是唯一一处"懂 Claude 字段名/事件语义"的代码——把它隔离在这里,
/// `TaskStore` / 协议核心保持 agent 中立,永不 import 任何 Claude 概念。其它 agent 仍走通用
/// 的 `/v1/task/*`。Claude 只是"一等公民",不是被特殊耦合。
///
/// 映射沿用 [docs/adapters/claude-code.md] 里论证过的那套语义(只是从 hook 里的 jq 搬进了 Swift):
///   - `UserPromptSubmit` → start   (一个 turn 开始 = 在干活)
///   - `PostToolUse`      → update  (在干活;也是 waiting→working 的恢复信号)
///   - `Notification`     → wait    (需要用户处理:权限请求 / 追问)
///   - `Stop` / `SessionEnd` → end  (turn 正常结束 / 会话关闭 = idle)
///   - 其余事件           → ignore  (安全无副作用,容忍用户多配了 hook)
///
/// 刻意**不读** `notification_type`(官方虽列了它,但这里靠时序天然区分 permission vs idle,
/// 字段缺失/语义变也不受影响):
///   - permission 通知在 turn 进行中触发 → 任务还在 → `wait` 命中 → 标记 waiting + 提醒。
///   - idle 通知在 `Stop` 之后触发 → 任务已被 `end` 移除 → `wait` 找不到任务 → 协议规定忽略。
///
/// 解析容错与 [TaskEvent] 一致:任何字段缺失/类型不符都降级为 nil,绝不影响休眠逻辑
/// (逻辑只看 `hook_event_name` + `session_id`)。
struct ClaudeHookEvent {
    /// 从 hook 事件派生出的中立动作。
    enum Action: Equatable {
        case start(name: String?)
        case update(tool: String?, detail: String?)
        case wait(message: String?)
        case end
        case ignore
    }

    let id: String?      // session_id → 中立协议的 task id
    let cwd: String?
    let action: Action

    /// 写进任务的来源标签,用于 UI 展示/分组。
    static let agentLabel = "claude-code"

    /// 宽容解析。仅当 body 根本不是 JSON 对象时返回 nil(交由 Router 忽略),保证服务端永不因 body 崩。
    static func parse(_ data: Data) -> ClaudeHookEvent? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return nil
        }

        let event = Self.string(dict, "hook_event_name")
        let id = Self.string(dict, "session_id")
        let cwd = Self.string(dict, "cwd")

        let action: Action
        switch event {
        case "UserPromptSubmit":
            // `prompt` 为用户提交的文本(权威 hooks 文档确认字段名为 `prompt`)。
            action = .start(name: Self.string(dict, "prompt"))

        case "PostToolUse":
            // 工具名铁实;细节按工具形状尽力取(Bash 看 command,Edit/Write/Read 看 file_path,等)。
            let tool = Self.string(dict, "tool_name")
            let detail = Self.toolDetail(dict["tool_input"] as? [String: Any])
            action = .update(tool: tool, detail: detail)

        case "Notification":
            action = .wait(message: Self.string(dict, "message"))

        case "Stop", "SessionEnd":
            action = .end

        default:
            action = .ignore
        }

        return ClaudeHookEvent(id: id, cwd: cwd, action: action)
    }

    // MARK: - 私有

    /// 取字符串字段;数字也强转字符串。缺失/类型不符 → nil。
    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 从 `tool_input` 里尽力凑一条"当前工作"细节(纯展示)。按各内置工具的参数名优先级取第一个非空。
    private static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "notebook_path"] {
            if let v = string(input, key), !v.isEmpty { return v }
        }
        return nil
    }
}
