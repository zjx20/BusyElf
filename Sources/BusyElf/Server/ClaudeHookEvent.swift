import Foundation

/// Claude Code hook 事件 → 中立动作的**内建适配器**。
///
/// Claude Code 的 HTTP hook(`type: "http"`)会把每个 hook 事件的原始 JSON 作为 POST body
/// 直接发到 `/claude/hooks`,无需用户在 hook 配置里写 `jq` + `curl`。本类型把这份原始 payload
/// 解析成 BusyElf 中立协议里的一个动作(start/update/wait/done/fail/ignore)。
///
/// **为什么单独一个文件**:这是唯一一处"懂 Claude 字段名/事件语义"的代码——把它隔离在这里,
/// `TaskStore` / 协议核心保持 agent 中立,永不 import 任何 Claude 概念。其它 agent 仍走通用
/// 的 `/v1/task/*`。Claude 只是"一等公民",不是被特殊耦合。
///
/// 映射:
///   - `UserPromptSubmit` → start   (一个 turn 开始 = 在干活)
///   - `SubagentStart`    → start    (子任务开始;agent_id 折进 id,parentId=session_id,name=agent_type)
///   - `PostToolUse`      → update  (在干活;也是 waiting/终态→working 的恢复信号)
///   - `MessageDisplay`   → update  (助手实时回复 delta → reply,replace/append)
///   - `Notification`     → wait / ignore  (按 notification_type:permission 才 wait,idle 忽略)
///   - `Stop`/`SessionEnd`/`SubagentStop` → done  (turn / 会话 / 子任务正常结束)
///   - `StopFailure`      → fail    (turn 因 API 错误结束:error / error_details / 错误原文)
///   - 其余事件           → ignore  (安全无副作用,容忍用户多配了 hook)
///
/// **子任务**:`agent_id`(仅在 subagent 内触发时存在)折进 `id`(`session_id#agent_id`),
/// `parentId = session_id`,`name = agent_type`(如 "Explore")。折叠只发生在本适配器内,
/// 中立层只看到一个带 `parentId` 的普通任务。
///
/// 解析容错与 [TaskEvent] 一致:任何字段缺失/类型不符都降级为 nil,绝不影响休眠逻辑
/// (逻辑只看 `hook_event_name` + `session_id`)。
struct ClaudeHookEvent {
    /// 从 hook 事件派生出的中立动作。
    enum Action: Equatable {
        case start(prompt: String?)
        case update(tool: String?, detail: String?, reply: String?, replyAppend: Bool)
        case wait(message: String?)
        case done(reply: String?)
        case fail(errorKind: String?, errorDetail: String?, reply: String?)
        case ignore
    }

    let id: String?        // 折叠后的 task id(主=session_id,子=session_id#agent_id)
    let parentId: String?  // 子任务=session_id,否则 nil
    let name: String?      // 子任务标签=agent_type,否则 nil
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
        let session = Self.string(dict, "session_id")
        let agentId = Self.string(dict, "agent_id")
        let agentType = Self.string(dict, "agent_type")
        let cwd = Self.string(dict, "cwd")

        // 折叠 id:在 subagent 内触发(有 agent_id)→ 子任务 "session#agent",parentId=session。
        let id: String?
        let parentId: String?
        if let session, let a = agentId, !a.isEmpty {
            id = "\(session)#\(a)"
            parentId = session
        } else {
            id = session
            parentId = nil
        }
        let name = (agentType?.isEmpty == false) ? agentType : nil   // 子任务标签

        let action: Action
        switch event {
        case "UserPromptSubmit":
            // `prompt` 为用户提交的文本(权威 hooks 文档确认字段名为 `prompt`)。
            action = .start(prompt: Self.string(dict, "prompt"))

        case "SubagentStart":
            // 子任务开始;标签/parentId 已在上面算好,这里无额外字段。
            action = .start(prompt: nil)

        case "PostToolUse":
            // 工具名铁实;细节按工具形状尽力取(Bash 看 command,Edit/Write/Read 看 file_path,等)。
            let tool = Self.string(dict, "tool_name")
            let detail = Self.toolDetail(dict["tool_input"] as? [String: Any])
            action = .update(tool: tool, detail: detail, reply: nil, replyAppend: false)

        case "MessageDisplay":
            // 助手文本流式输出:delta 是增量。新消息首批(index==0)替换,后续追加。
            let delta = Self.string(dict, "delta")
            let index = Self.int(dict, "index") ?? 0
            action = .update(tool: nil, detail: nil, reply: delta, replyAppend: index != 0)

        case "Notification":
            // 读 notification_type 区分:permission(真等待)才 wait;idle 等不产生等待项。
            let kind = Self.string(dict, "notification_type")
            if kind == "permission_prompt" || kind == "elicitation_dialog" {
                action = .wait(message: Self.string(dict, "message"))
            } else {
                action = .ignore
            }

        case "Stop", "SessionEnd", "SubagentStop":
            // 正常结束:last_assistant_message 是最终回复文本(无需解析 transcript)。
            action = .done(reply: Self.string(dict, "last_assistant_message"))

        case "StopFailure":
            // turn 因 API 错误结束。error=类型;last_assistant_message 此处为错误原文。
            let kind = Self.string(dict, "error")
            let detail = Self.string(dict, "error_details") ?? Self.string(dict, "last_assistant_message")
            action = .fail(errorKind: kind, errorDetail: detail,
                           reply: Self.string(dict, "last_assistant_message"))

        default:
            action = .ignore
        }

        return ClaudeHookEvent(id: id, parentId: parentId, name: name, cwd: cwd, action: action)
    }

    // MARK: - 私有

    /// 取字符串字段;数字也强转字符串。缺失/类型不符 → nil。
    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 取整型字段。缺失/类型不符 → nil。
    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    /// 从 `tool_input` 里尽力凑一条"当前工作"细节(纯展示)。按各内置工具的参数名优先级取第一个非空。
    private static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "notebook_path", "description", "prompt"] {
            if let v = string(input, key), !v.isEmpty { return v }
        }
        return nil
    }
}
