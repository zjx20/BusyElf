import Foundation

/// 真相源:`[id: TaskSession]`,串行队列保护。
///
/// 协议动词全部走幂等 upsert/标记;每次变更后 `reconcile()`:
///  - 驱动 `SleepGuard`(存在 working → 阻止休眠;终态不阻止)。
///  - 在主线程回调 `onChange`(刷新图标 + popover)。
///  - working→waiting 跳变时回调 `onAttention`(发系统横幅,已去抖)。
///  - →failed 跳变时回调 `onTerminalAlert`(发紧急横幅,已去抖)。
///
/// 用"集合成员"而非"+1/−1 整数计数":事件 at-least-once 且可能丢失,
/// 整数会漂移成负数或卡正从而永久阻止休眠——本应用绝不能有的 bug。
///
/// 终态(done/failed)留在字典里展示,靠 seen 生命周期清理:
/// popover 打开 → `markTerminalSeen`(清角标),关闭 → `purgeSeenTerminal`(下次打开就消失)。
final class TaskStore {
    static let shared = TaskStore()

    private let queue = DispatchQueue(label: "elf.busyelf.taskstore")
    private var sessions: [String: TaskSession] = [:]

    /// 终态项的兜底清理(防止用户从不打开 popover 导致字典无界增长)。
    private static let maxTerminalAge: TimeInterval = 30 * 60   // 超龄终态项移除
    private static let maxTerminalCount = 50                    // 终态项数硬上限
    private static let orphanGraceSeconds: TimeInterval = 300   // 孤儿子任务降级阈值

    /// 看门狗:working 任务无活动超过它就视为"可能已断",不再阻止休眠(由 AppConfig 启动时注入)。
    private var inactivityTimeout: TimeInterval = AppConfig.defaultInactivityTimeout
    /// 疑似已断的顶层任务在无活动这么久后兜底移除(防 working 项无界堆积;远大于上面的阈值,留足查看时间)。
    private static let stalledReapAfter: TimeInterval = 6 * 3600
    /// 调度截止点时的小余量,确保 fire 时确实越过阈值(避免边界相等漏判)。
    private static let watchdogMargin: TimeInterval = 0.2
    /// 一次性看门狗定时器,跑在串行 `queue` 上;无 working 任务时取消 → 回到 0 idle CPU。
    private var watchdog: DispatchSourceTimer?

    /// 每次变更后在主线程回调,携带排序后的快照。
    var onChange: (([TaskSession]) -> Void)?
    /// 任务进入 waiting(→waiting 跳变)时在主线程回调一次。
    var onAttention: ((TaskSession) -> Void)?
    /// 任务进入 failed(→failed 跳变)时在主线程回调一次(紧急横幅)。
    var onTerminalAlert: ((TaskSession) -> Void)?

    private init() {}

    // MARK: - 协议动词

    /// start:upsert → working,记 prompt / 子任务标签(name)/ parentId。一个新 turn 的开始 → 清旧回复/动作。
    func start(id: String, parentId: String?, name: String?, prompt: String?, agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            var s = self.sessions[id] ?? Self.makeSession(id: id, status: .working, now: now)
            s.status = .working
            self.clearTerminalMarks(&s)
            s.reply = nil          // 新 turn:旧回复作废
            s.activity = ""        // 新 turn:旧动作作废
            if let prompt, !prompt.isEmpty { s.prompt = prompt }
            self.applyMeta(&s, parentId: parentId, name: name, agent: agent, cwd: cwd)
            s.lastSeen = now
            self.sessions[id] = s
            self.reconcile()
        }
    }

    /// update:upsert → working,**复活终态**,刷新当前动作 / 回复。
    /// upsert 是刻意的:即使漏掉 start(中途启动),一条 update 也能建/恢复任务、重新阻止休眠。
    /// 漏了 SubagentStart 时,带 parentId/name 也能把子任务正确建成"带父、带名"的子行。
    func update(id: String, parentId: String?, name: String?,
                tool: String?, detail: String?,
                reply: String?, replyAppend: Bool,
                agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            var s = self.sessions[id] ?? Self.makeSession(id: id, status: .working, now: now)
            s.status = .working
            self.clearTerminalMarks(&s)
            if let reply, !reply.isEmpty {
                s.reply = replyAppend ? ((s.reply ?? "") + reply) : reply
            }
            // 当前动作主行:有工具用"工具: 细节",否则退化到最新回复。
            if let act = Self.activity(tool: tool, detail: detail, reply: s.reply) {
                s.activity = act
            }
            self.applyMeta(&s, parentId: parentId, name: name, agent: agent, cwd: cwd)
            s.lastSeen = now
            self.sessions[id] = s
            self.reconcile()
        }
    }

    /// wait:upsert → waiting(中立原语:总是创建)。记录 message,点亮"需要关注"。
    /// "过滤 idle 通知"是 Claude 适配器靠 notification_type 不调 wait 实现,不进本层。
    func wait(id: String, message: String?, parentId: String?, name: String?, agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            let existing = self.sessions[id]
            let wasWaiting = (existing?.status == .waiting)
            var s = existing ?? Self.makeSession(id: id, status: .waiting, now: now)
            s.status = .waiting
            self.clearTerminalMarks(&s)
            s.waitingMessage = message
            self.applyMeta(&s, parentId: parentId, name: name, agent: agent, cwd: cwd)
            s.lastSeen = now
            self.sessions[id] = s
            // 只在进入 waiting 那一刻提醒一次(去抖)。
            self.reconcile(attention: wasWaiting ? nil : s)
        }
    }

    /// done:working/waiting → done(不删)。记 endedAt、seen=false(供绿点提示)。failed 不被 done 覆盖。
    /// `∅` 时忽略(无前置任务不凭空造完成项)。
    func done(id: String, reply: String?) {
        queue.async {
            guard var s = self.sessions[id], s.status != .failed else { return }
            let now = Date()
            s.status = .done
            if let reply, !reply.isEmpty { s.reply = reply }
            s.waitingMessage = nil
            s.endedAt = now
            s.seen = false
            s.lastSeen = now
            self.sessions[id] = s
            self.reconcile()
        }
    }

    /// fail:任意态 → failed(失败优先,覆盖 done)。`∅` 时 upsert 造最小 failed 项
    /// (StopFailure 可能是中途启动后第一个见到的事件)。
    func fail(id: String, parentId: String?, name: String?,
              errorKind: String?, errorDetail: String?, reply: String?,
              agent: String?, cwd: String?) {
        queue.async {
            let now = Date()
            let existing = self.sessions[id]
            let wasFailed = (existing?.status == .failed)
            var s = existing ?? Self.makeSession(id: id, status: .failed, now: now)
            s.status = .failed
            s.errorKind = errorKind
            s.errorDetail = errorDetail
            if let reply, !reply.isEmpty { s.reply = reply }
            s.waitingMessage = nil
            s.endedAt = now
            s.seen = false
            self.applyMeta(&s, parentId: parentId, name: name, agent: agent, cwd: cwd)
            s.lastSeen = now
            self.sessions[id] = s
            // 只在进入 failed 那一刻提醒一次(去抖)。
            self.reconcile(failedAlert: wasFailed ? nil : s)
        }
    }

    /// remove:真正移除(用户手动 ×)。级联移除其子任务;幂等。
    func remove(id: String) {
        queue.async {
            var removed = self.sessions.removeValue(forKey: id) != nil
            for childId in self.sessions.values.filter({ $0.parentId == id }).map({ $0.id }) {
                self.sessions.removeValue(forKey: childId)
                removed = true
            }
            guard removed else { return }
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

    // MARK: - 配置

    /// 注入"无活动超时"(AppDelegate 从 AppConfig 注入;`/debug/timeout` 测试用)。
    /// 走队列保证与 reconcile/看门狗的读取串行;设后立刻重算并重排看门狗。
    func setInactivityTimeout(_ seconds: TimeInterval) {
        queue.async {
            self.inactivityTimeout = max(1, seconds)   // 测试可设很小;生产经 AppConfig 已 clamp ≥60
            self.reconcile()
        }
    }

    /// 是否存在"仍在阻止休眠"的 working 任务:working 且未超过无活动阈值(疑似已断的不算)。
    /// 纯函数,便于单测;集合成员判定,绝不用整数计数。
    static func hasBlockingWorking(_ sessions: [TaskSession], asOf now: Date, timeout: TimeInterval) -> Bool {
        sessions.contains { $0.status == .working && !$0.isStalled(asOf: now, threshold: timeout) }
    }

    // MARK: - 终态提示生命周期

    /// popover 打开:把当前所有终态项标记为 seen(清菜单栏角标),但**本次仍显示**。
    func markTerminalSeen() {
        queue.async {
            var changed = false
            for id in Array(self.sessions.keys) {
                if var s = self.sessions[id], s.isTerminal, !s.seen {
                    s.seen = true
                    self.sessions[id] = s
                    changed = true
                }
            }
            if changed { self.reconcile() }
        }
    }

    /// popover 关闭:清理掉已 seen 的终态项 → 下次打开它们不再显示。
    func purgeSeenTerminal() {
        queue.async {
            let before = self.sessions.count
            for id in Array(self.sessions.keys) {
                if let s = self.sessions[id], s.isTerminal, s.seen {
                    self.sessions.removeValue(forKey: id)
                }
            }
            if self.sessions.count != before { self.reconcile() }
        }
    }

    /// 异步取一份排序后的快照(在主线程回调)。
    func snapshot(_ completion: @escaping ([TaskSession]) -> Void) {
        queue.async {
            let snap = self.sortedLocked()
            DispatchQueue.main.async { completion(snap) }
        }
    }

    // MARK: - 调试/观测(仅 BUSYELF_DEBUG=1 时经 /debug/state 暴露)

    /// 同步读一份内部状态快照的 JSON。`queue.sync` 兼作"写后读"屏障:
    /// 之前 enqueue 的所有 async 变更都已落库,故测试断言无需 sleep。
    func debugStateJSON() -> String {
        queue.sync {
            let now = Date()
            let sorted = self.sortedLocked()
            let timeout = self.inactivityTimeout
            // blocking = 派生的"仍在阻止休眠的 working"(疑似已断的不算);assertionHeld = 实际持有的电源断言。
            // 二者稳态应一致;看门狗 fire 后 setBlocked(false) 才会让 assertionHeld 翻 false(故 E2E 用它验证 timer)。
            let hasWorking = Self.hasBlockingWorking(Array(self.sessions.values), asOf: now, timeout: timeout)
            let hasUnseenDone = self.sessions.values.contains { $0.status == .done && !$0.seen }
            let hasUnseenFailed = self.sessions.values.contains { $0.status == .failed && !$0.seen }
            let root: [String: Any] = [
                "blocking": hasWorking,
                "hasWorking": hasWorking,
                "assertionHeld": SleepGuard.shared.isBlocking,
                "inactivityTimeout": timeout,
                "hasUnseenDone": hasUnseenDone,
                "hasUnseenFailed": hasUnseenFailed,
                "count": sorted.count,
                "sessions": sorted.map { Self.debugDict($0, now: now, timeout: timeout) },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }
    }

    private static func debugDict(_ s: TaskSession, now: Date, timeout: TimeInterval) -> [String: Any] {
        var d: [String: Any] = [
            "id": s.id,
            "status": statusString(s.status),
            "seen": s.seen,
            "isTerminal": s.isTerminal,
            "isSubtask": s.isSubtask,
            "stalled": s.isStalled(asOf: now, threshold: timeout),
            "sinceLastSeen": s.sinceLastSeen(asOf: now),
            "startedAt": s.startedAt.timeIntervalSince1970,
            "lastSeen": s.lastSeen.timeIntervalSince1970,
        ]
        if let v = s.parentId { d["parentId"] = v }
        if !s.name.isEmpty { d["name"] = s.name }
        if let v = s.prompt { d["prompt"] = v }
        if !s.activity.isEmpty { d["activity"] = s.activity }
        if let v = s.reply { d["reply"] = v }
        if let v = s.waitingMessage { d["waitingMessage"] = v }
        if let v = s.errorKind { d["errorKind"] = v }
        if let v = s.errorDetail { d["errorDetail"] = v }
        if let v = s.agent { d["agent"] = v }
        if let v = s.cwd { d["cwd"] = v }
        if let v = s.totalTokens { d["totalTokens"] = v }
        if let v = s.endedAt { d["endedAt"] = v.timeIntervalSince1970 }
        return d
    }

    private static func statusString(_ s: TaskStatus) -> String {
        switch s {
        case .working: return "working"
        case .waiting: return "waiting"
        case .done:    return "done"
        case .failed:  return "failed"
        }
    }

    #if DEBUG
    // MARK: - 单元测试辅助(仅 DEBUG 构建)

    /// 同步取快照(`queue.sync` 屏障,flush 所有 pending async)。供白盒断言。
    func snapshotSync() -> [TaskSession] { queue.sync { sortedLocked() } }

    /// 按 id 同步取单个 session。
    func sessionSync(_ id: String) -> TaskSession? { queue.sync { sessions[id] } }

    /// 同步清空(测试隔离),并解除休眠阻止 + 取消看门狗定时器(防测试间泄漏)。
    func resetSync() {
        queue.sync {
            sessions.removeAll()
            watchdog?.cancel()
            watchdog = nil
        }
        SleepGuard.shared.setBlocked(false)
    }
    #endif

    // MARK: - 私有

    /// 在串行队列上调用。先兜底清理,聚合派生量,驱动 SleepGuard,并在主线程回调。
    private func reconcile(attention: TaskSession? = nil, failedAlert: TaskSession? = nil) {
        pruneLocked()
        let now = Date()
        let hasWorking = Self.hasBlockingWorking(Array(sessions.values), asOf: now, timeout: inactivityTimeout)
        SleepGuard.shared.setBlocked(hasWorking)
        scheduleWatchdogLocked(asOf: now)

        let snap = sortedLocked()
        DispatchQueue.main.async {
            self.onChange?(snap)
            if let attention { self.onAttention?(attention) }
            if let failedAlert { self.onTerminalAlert?(failedAlert) }
        }
    }

    /// 安排下一次"无活动重算":取所有 working 任务最近的关键时刻
    ///  - 未疑似已断的:`lastSeen + inactivityTimeout`(到点要放行休眠);
    ///  - 已疑似已断的:`lastSeen + stalledReapAfter`(到点要兜底移除)。
    /// 无 working 任务则取消定时器(放行后机器可休眠,回到 0 idle CPU)。在串行 `queue` 上调用。
    private func scheduleWatchdogLocked(asOf now: Date) {
        var nextDeadline: Date?
        for s in sessions.values where s.status == .working {
            let stalled = s.isStalled(asOf: now, threshold: inactivityTimeout)
            let d = s.lastSeen.addingTimeInterval(stalled ? Self.stalledReapAfter : inactivityTimeout)
            if nextDeadline == nil || d < nextDeadline! { nextDeadline = d }
        }
        watchdog?.cancel()
        guard let deadline = nextDeadline else { watchdog = nil; return }

        let interval = max(1, deadline.timeIntervalSince(now)) + Self.watchdogMargin
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)   // 一次性;fire 后由新的 reconcile 重排
        timer.setEventHandler { [weak self] in self?.reconcile() }
        watchdog = timer
        timer.resume()
    }

    /// 兜底:孤儿子任务降级 + 终态项 TTL / 数量上限。在串行队列上调用。
    private func pruneLocked() {
        let now = Date()

        // 孤儿子任务降级:父已不在 / 已终态,且子久无进展 → 降为 done,
        // 否则子卡在 working 会永久阻止休眠。
        for id in Array(sessions.keys) {
            guard var s = sessions[id], s.status == .working, let pid = s.parentId else { continue }
            let parentGone = sessions[pid] == nil || sessions[pid]?.isTerminal == true
            if parentGone, s.sinceLastSeen(asOf: now) > Self.orphanGraceSeconds {
                s.status = .done
                s.endedAt = now
                s.seen = false
                sessions[id] = s
            }
        }

        // 疑似已断的顶层 working 任务超久无活动 → 兜底移除(级联子任务)。
        // 它早已不阻止休眠(派生 stalled 排除),这里只为防 working 项无界堆积;远长于无活动阈值,
        // 用户有充足时间在 popover 看到"可能已断"。不降级为 done/failed,避免谎报完成或误触失败横幅。
        for id in Array(sessions.keys) {
            guard let s = sessions[id], s.status == .working, s.parentId == nil else { continue }
            if s.sinceLastSeen(asOf: now) > Self.stalledReapAfter {
                sessions.removeValue(forKey: id)
                for childId in sessions.values.filter({ $0.parentId == id }).map({ $0.id }) {
                    sessions.removeValue(forKey: childId)
                }
            }
        }

        // 终态项超龄移除(无论是否 seen)。
        for id in Array(sessions.keys) {
            if let s = sessions[id], s.isTerminal,
               let e = s.endedAt, now.timeIntervalSince(e) > Self.maxTerminalAge {
                sessions.removeValue(forKey: id)
            }
        }

        // 终态项数硬上限:超出按 endedAt 删最旧。
        let terminals = sessions.values.filter { $0.isTerminal }
        if terminals.count > Self.maxTerminalCount {
            let overflow = terminals
                .sorted { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
                .prefix(terminals.count - Self.maxTerminalCount)
            for s in overflow { sessions.removeValue(forKey: s.id) }
        }
    }

    /// 稳定排序:活动项在前、终态项在后;组内按开始时间升序(任务增删时顺序不跳)。在串行队列上调用。
    private func sortedLocked() -> [TaskSession] {
        sessions.values.sorted { a, b in
            if a.isTerminal != b.isTerminal { return !a.isTerminal }   // 活动在前
            if a.startedAt != b.startedAt { return a.startedAt < b.startedAt }
            return a.id < b.id
        }
    }

    /// 新建一个最小任务壳(各富字段默认 nil/false)。
    private static func makeSession(id: String, status: TaskStatus, now: Date) -> TaskSession {
        TaskSession(id: id, agent: nil, cwd: nil, name: "", activity: "",
                    waitingMessage: nil, status: status, startedAt: now, lastSeen: now)
    }

    /// 复活终态时清掉终态痕迹(错误信息 / endedAt / seen)。
    private func clearTerminalMarks(_ s: inout TaskSession) {
        s.waitingMessage = nil
        s.errorKind = nil
        s.errorDetail = nil
        s.endedAt = nil
        s.seen = false
    }

    /// 落上 parentId / name / agent / cwd(都只在提供且有意义时写,不覆盖已有的稳定值)。
    private func applyMeta(_ s: inout TaskSession, parentId: String?, name: String?, agent: String?, cwd: String?) {
        if let parentId, !parentId.isEmpty, s.parentId == nil { s.parentId = parentId }
        if let name, !name.isEmpty, s.name.isEmpty { s.name = name }
        if let agent, !agent.isEmpty { s.agent = agent }
        if let cwd, !cwd.isEmpty { s.cwd = cwd }
    }

    /// 由 tool/detail/reply 拼一条"当前动作";全空则返回 nil(不覆盖旧值)。
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
