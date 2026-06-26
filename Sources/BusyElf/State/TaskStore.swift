import Foundation

/// 真相源:`[id: TaskSession]`,串行队列保护。
///
/// 协议四动词全部走幂等 upsert/remove;每次变更后 `reconcile()`:
///  - 驱动 `SleepGuard`(存在 working → 阻止休眠)。
///  - 在主线程回调 `onChange`(刷新图标 + popover)。
///  - working→waiting 跳变时回调 `onAttention`(发系统横幅,已去抖)。
///
/// 用"集合成员"而非"+1/−1 整数计数":事件 at-least-once 且可能丢失,
/// 整数会漂移成负数或卡正从而永久阻止休眠——本应用绝不能有的 bug。
final class TaskStore {
    static let shared = TaskStore()

    private let queue = DispatchQueue(label: "elf.busyelf.taskstore")
    private var sessions: [String: TaskSession] = [:]

    /// 每次变更后在主线程回调,携带排序后的快照。
    var onChange: (([TaskSession]) -> Void)?
    /// 任务进入 waiting(working→waiting 跳变)时在主线程回调一次。
    var onAttention: ((TaskSession) -> Void)?

    private init() {}

    // MARK: - 协议动词

    /// start:upsert → working。漏过也无妨,出现首个 working 时开始阻止休眠。
    func start(id: String, name: String?, agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            if var s = self.sessions[id] {
                s.status = .working
                s.waitingMessage = nil
                if let name, !name.isEmpty { s.name = name }
                if let agent, !agent.isEmpty { s.agent = agent }
                if let cwd, !cwd.isEmpty { s.cwd = cwd }
                s.lastSeen = now
                self.sessions[id] = s
            } else {
                self.sessions[id] = TaskSession(
                    id: id,
                    agent: agent,
                    cwd: cwd,
                    name: name ?? "",
                    activity: "",
                    waitingMessage: nil,
                    status: .working,
                    startedAt: now,
                    lastSeen: now)
            }
            self.reconcile()
        }
    }

    /// update:upsert → working;若原为 waiting 则重新接管。刷新"当前活动"。
    /// upsert 是刻意的:即使漏掉 start,一条 update 也能恢复任务、重新阻止休眠。
    func update(id: String, tool: String?, detail: String?, reply: String?, agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            var s = self.sessions[id] ?? TaskSession(
                id: id,
                agent: agent,
                cwd: cwd,
                name: "",
                activity: "",
                waitingMessage: nil,
                status: .working,
                startedAt: now,
                lastSeen: now)
            s.status = .working
            s.waitingMessage = nil
            if let activity = Self.activity(tool: tool, detail: detail, reply: reply) {
                s.activity = activity
            }
            if let agent, !agent.isEmpty { s.agent = agent }
            if let cwd, !cwd.isEmpty { s.cwd = cwd }
            s.lastSeen = now
            self.sessions[id] = s
            self.reconcile()
        }
    }

    /// wait:仅更新已存在的任务 → waiting。不存在则忽略(避免迟到 wait 造幽灵项)。
    func wait(id: String, message: String?) {
        queue.async {
            guard var s = self.sessions[id] else { return }
            let wasWaiting = (s.status == .waiting)
            s.status = .waiting
            s.waitingMessage = message
            s.lastSeen = Date()
            self.sessions[id] = s
            // 只在进入 waiting 那一刻提醒一次(去抖)。
            self.reconcile(attention: wasWaiting ? nil : s)
        }
    }

    /// end:移除(幂等;不存在也无妨)。移除后若再无 working 则恢复休眠。
    func end(id: String) {
        queue.async {
            guard self.sessions.removeValue(forKey: id) != nil else { return }
            self.reconcile()
        }
    }

    /// UI"全部结束":一次性清空所有任务并解除休眠阻止。
    func removeAll() {
        queue.async {
            guard !self.sessions.isEmpty else { return }
            self.sessions.removeAll()
            self.reconcile()
        }
    }

    /// 异步取一份排序后的快照(在主线程回调)。
    func snapshot(_ completion: @escaping ([TaskSession]) -> Void) {
        queue.async {
            let snap = self.sortedLocked()
            DispatchQueue.main.async { completion(snap) }
        }
    }

    // MARK: - 私有

    /// 在串行队列上调用。聚合派生量,驱动 SleepGuard,并在主线程回调。
    private func reconcile(attention: TaskSession? = nil) {
        let hasWorking = sessions.values.contains { $0.status == .working }
        SleepGuard.shared.setBlocked(hasWorking)

        let snap = sortedLocked()
        DispatchQueue.main.async {
            self.onChange?(snap)
            if let attention {
                self.onAttention?(attention)
            }
        }
    }

    /// 稳定排序:按开始时间升序(任务增删时顺序不跳)。在串行队列上调用。
    private func sortedLocked() -> [TaskSession] {
        sessions.values.sorted { a, b in
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
    }

    /// 由 tool/detail/reply 拼一条"当前活动";全空则返回 nil(不覆盖旧值)。
    private static func activity(tool: String?, detail: String?, reply: String?) -> String? {
        let t = tool?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let d = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty {
            return d.isEmpty ? t : "\(t): \(d)"
        }
        let r = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return r.isEmpty ? nil : r
    }
}
