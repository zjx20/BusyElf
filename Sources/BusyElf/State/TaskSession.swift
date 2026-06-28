import Foundation

enum TaskStatus {
    case working   // 在干活 → 阻止休眠
    case waiting   // 等用户 → 放行休眠,但需关注
    case done      // 正常完成 → 放行休眠;绿点提示,看一次后清理
    case failed    // 异常停止(API 错误)→ 放行休眠;红点紧急提示
}

/// 单个 agent 任务的展示 + 状态。值类型,真相源是 `TaskStore` 里的字典。
///
/// 字段大多 best-effort:有就展示,没有就降级,绝不影响休眠逻辑(只看 status==.working)。
struct TaskSession: Identifiable {
    let id: String              // 来自 agent 的 task/session id(子任务 = "sessionId#agentId");字典 key
    var agent: String?          // 来源标签 "claude-code"/"codex";展示/分组
    var cwd: String?            // 工作目录;basename 作项目名(若适配器提供)
    var name: String            // 任务名 / 子任务标签(如 "Explore");best-effort
    var activity: String        // 当前动作主行:工具+细节 或 最近回复(best-effort)
    var waitingMessage: String? // wait 时需要用户做什么
    var status: TaskStatus
    let startedAt: Date
    var lastSeen: Date

    // ── 富信息(展示用,全可选)──
    var prompt: String?         // 触发本轮的用户提示词
    var reply: String?          // agent 当前/最终回复文本(流式累积或 last_assistant_message)
    var errorKind: String?      // 失败类型(如 "rate_limit");中立字符串
    var errorDetail: String?    // 失败细节 / API 错误原文
    var totalTokens: Int?       // 预留:token 消耗(本期不展示)

    // ── 子任务关联 ──
    var parentId: String?       // 父任务 id;非 nil 即子任务(agent id 已折进自身 id)

    // ── 终态提示生命周期 ──
    var seen: Bool = false      // 该终态是否已被用户在 popover 中看到
    var endedAt: Date?          // 进入终态的时刻(终态时长冻结 / TTL 清理用)

    /// 终态:已完成或已失败。留在字典里展示,不阻止休眠,靠 seen 生命周期清理。
    var isTerminal: Bool { status == .done || status == .failed }
    /// 子任务(subagent):有父任务关联。
    var isSubtask: Bool { parentId != nil }

    /// 展示用项目名:优先 cwd 的 basename,退化到 name,再退化到 id。
    var projectName: String {
        if let cwd, !cwd.isEmpty {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty, base != "/" { return base }
        }
        if !name.isEmpty { return name }
        return id
    }

    /// 已运行时长。终态冻结在 `endedAt`(不再走秒);活动态相对传入的"现在"。
    func elapsed(asOf now: Date) -> TimeInterval {
        let ref = isTerminal ? (endedAt ?? lastSeen) : now
        return max(0, ref.timeIntervalSince(startedAt))
    }

    /// 距上次"有进展"的时长,用于"似乎仍活跃"警示与卡死提示。
    func sinceLastSeen(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastSeen))
    }

    /// working 且长时间无进展 → 纯展示提示可能卡死(不自动处理)。
    func isStuck(asOf now: Date, threshold: TimeInterval = 120) -> Bool {
        status == .working && sinceLastSeen(asOf: now) > threshold
    }

    /// working 且超过"无活动阈值" → 疑似已断(看门狗):**不再阻止休眠**(派生,不改 status)。
    /// 与 `isStuck` 同形但阈值更大、语义更强(stuck 只是 UI ⚠ 提示,stalled 会放行休眠)。
    /// 收到任何新进展(`lastSeen` 刷新)即自动回到非 stalled,休眠重新被阻止。
    func isStalled(asOf now: Date, threshold: TimeInterval) -> Bool {
        status == .working && sinceLastSeen(asOf: now) > threshold
    }

    /// 强制结束前判断是否"看起来仍活跃"(近期有 update),用于确认文案警示。
    func looksActive(asOf now: Date, within: TimeInterval = 30) -> Bool {
        status == .working && sinceLastSeen(asOf: now) < within
    }
}

/// 时长 / 相对时间格式化。
enum Format {
    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        // 用 %ld 匹配 64 位 Swift Int(%d 取 32 位 C int,大值会截断)。
        if h > 0 { return String(format: "%ldh %02ldm", h, m) }
        if m > 0 { return String(format: "%ldm %02lds", m, sec) }
        return String(format: "%lds", sec)
    }

    /// "12s 前" / "3m 前" 这类相对短语。
    static func ago(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        if s < 60 { return "\(s)s 前" }
        if s < 3600 { return "\(s / 60)m 前" }
        return "\(s / 3600)h 前"
    }
}
