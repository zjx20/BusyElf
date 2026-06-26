import Foundation

enum TaskStatus {
    case working   // 在干活 → 阻止休眠
    case waiting   // 等用户 → 放行休眠,但需关注
}

/// 单个 agent 任务的展示 + 状态。值类型,真相源是 `TaskStore` 里的字典。
struct TaskSession: Identifiable {
    let id: String              // 来自 agent 的 task/session id;字典 key
    var agent: String?          // 来源标签 "claude-code"/"codex";展示/分组
    var cwd: String?            // 工作目录;basename 作项目名(若适配器提供)
    var name: String            // 任务名/prompt(best-effort)
    var activity: String        // 当前工具+细节摘要(best-effort)
    var waitingMessage: String? // wait 时需要用户做什么
    var status: TaskStatus
    let startedAt: Date
    var lastSeen: Date

    /// 展示用项目名:优先 cwd 的 basename,退化到 name,再退化到 id。
    var projectName: String {
        if let cwd, !cwd.isEmpty {
            let base = (cwd as NSString).lastPathComponent
            if !base.isEmpty, base != "/" { return base }
        }
        if !name.isEmpty { return name }
        return id
    }

    /// 已运行时长(相对传入的"现在")。由 popover 打开时的 1s ticker 提供 now。
    func elapsed(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// 距上次"有进展"的时长,用于"似乎仍活跃"警示与卡死提示。
    func sinceLastSeen(asOf now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(lastSeen))
    }

    /// working 且长时间无进展 → 纯展示提示可能卡死(不自动处理)。
    func isStuck(asOf now: Date, threshold: TimeInterval = 120) -> Bool {
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
