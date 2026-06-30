import XCTest
@testable import BusyElf

/// 白盒:TaskStore 状态机内部逻辑。
/// 用 `snapshotSync()`/`sessionSync()`(queue.sync 屏障)同步断言,无需 sleep。
final class TaskStoreTests: XCTestCase {
    private let store = TaskStore.shared

    override func setUp() {
        super.setUp()
        store.onChange = nil
        store.onAttention = nil
        store.onTerminalAlert = nil
        store.resetSync()   // queue.sync 屏障:flush 上个测试残留的 reconcile(其 main.async 回调随之入队)
        // 再排空 main 队列:那些残留回调此刻执行时读到的是 nil 回调 → 无副作用,
        // 不会在本测试 waitForExpectations 期间误触发本测试的 onAttention/onTerminalAlert。
        let drained = expectation(description: "drain main queue")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    // 便捷
    private func s(_ id: String) -> TaskSession? { store.sessionSync(id) }
    private var blocking: Bool { store.snapshotSync().contains { $0.status == .working } }

    private func start(_ id: String, parentId: String? = nil, name: String? = nil,
                       prompt: String? = nil, agent: String? = nil, cwd: String? = nil) {
        store.start(id: id, parentId: parentId, name: name, prompt: prompt, agent: agent, cwd: cwd)
    }
    private func update(_ id: String, parentId: String? = nil, name: String? = nil,
                        tool: String? = nil, detail: String? = nil,
                        reply: String? = nil, replyAppend: Bool = false,
                        toolComplete: Bool = false,
                        toolFailed: Bool = false, toolError: String? = nil) {
        store.update(id: id, parentId: parentId, name: name, tool: tool, detail: detail,
                     reply: reply, replyAppend: replyAppend, toolComplete: toolComplete,
                     toolFailed: toolFailed, toolError: toolError,
                     agent: nil, cwd: nil)
    }

    // MARK: - 创建 / 阻止休眠

    func testStartCreatesWorkingAndBlocks() {
        start("a", prompt: "hi", cwd: "/c")
        XCTAssertEqual(s("a")?.status, .working)
        XCTAssertEqual(s("a")?.prompt, "hi")
        XCTAssertTrue(blocking)
    }

    /// 需求1:漏 start,update 也 upsert 创建(中途接管)。
    func testUpdateUpsertsWhenStartMissed() {
        update("b", tool: "Bash", detail: "ls")
        XCTAssertEqual(s("b")?.status, .working)
        XCTAssertEqual(s("b")?.activity, "Bash: ls")
        XCTAssertTrue(blocking)
    }

    func testWaitCreatesWaitingAndReleases() {
        update("c", tool: "Bash", detail: "x")
        XCTAssertTrue(blocking)
        store.wait(id: "c", message: "授权?", parentId: nil, name: nil, agent: nil, cwd: nil)
        XCTAssertEqual(s("c")?.status, .waiting)
        XCTAssertEqual(s("c")?.waitingMessage, "授权?")
        XCTAssertFalse(blocking)            // waiting 不阻止休眠
    }

    // MARK: - 终态

    func testDoneIgnoredWhenAbsent() {
        store.done(id: "ghost", reply: "x")
        XCTAssertNil(s("ghost"))            // 无前置任务不凭空造完成项
    }

    func testStopMarksDoneAndKeepsItem() {
        start("d")
        store.done(id: "d", reply: "final")
        XCTAssertEqual(s("d")?.status, .done)
        XCTAssertEqual(s("d")?.reply, "final")
        XCTAssertNotNil(s("d")?.endedAt)
        XCTAssertFalse(s("d")?.seen ?? true)
        XCTAssertFalse(blocking)            // 终态放行休眠
    }

    func testFailCreatesWhenAbsent() {
        store.fail(id: "e", parentId: nil, name: nil, errorKind: "rate_limit",
                   errorDetail: "API Error", reply: nil, agent: nil, cwd: nil)
        XCTAssertEqual(s("e")?.status, .failed)
        XCTAssertEqual(s("e")?.errorKind, "rate_limit")
        XCTAssertFalse(blocking)
    }

    /// 失败优先:done 不覆盖 failed。
    func testFailedNotOverwrittenByDone() {
        store.fail(id: "e", parentId: nil, name: nil, errorKind: "overloaded",
                   errorDetail: nil, reply: nil, agent: nil, cwd: nil)
        store.done(id: "e", reply: "x")
        XCTAssertEqual(s("e")?.status, .failed)
    }

    /// 复活:update 把终态拉回 working,并清掉终态痕迹。
    func testUpdateRevivesTerminal() {
        start("f")
        store.done(id: "f", reply: "r")
        XCTAssertEqual(s("f")?.status, .done)
        update("f", tool: "Edit", detail: "a.go")
        XCTAssertEqual(s("f")?.status, .working)
        XCTAssertNil(s("f")?.endedAt)
        XCTAssertNil(s("f")?.errorKind)
        XCTAssertTrue(blocking)
    }

    // MARK: - 回复 / 活动

    func testStartClearsReplyOnNewTurn() {
        update("g", reply: "old turn", replyAppend: false)
        XCTAssertEqual(s("g")?.reply, "old turn")
        start("g", prompt: "new turn")
        XCTAssertNil(s("g")?.reply)         // 新 turn 清旧回复
    }

    func testReplyReplaceThenAppend() {
        update("h", reply: "A", replyAppend: false)
        update("h", reply: "B", replyAppend: true)
        XCTAssertEqual(s("h")?.reply, "AB")
        update("h", reply: "C", replyAppend: false)   // 新消息替换
        XCTAssertEqual(s("h")?.reply, "C")
    }

    /// 主行"当前动作":工具优先,退化到最新回复;最近事件覆盖。
    func testActivityToolThenReply() {
        update("i", tool: "Bash", detail: "cmd")
        XCTAssertEqual(s("i")?.activity, "Bash: cmd")
        update("i", reply: "正在说话")
        XCTAssertEqual(s("i")?.activity, "正在说话")
    }

    /// toolComplete(工具完成 ✓):置位/新 turn 清零/纯元数据更新不误清;且永不改 status。
    func testToolCompleteLifecycle() {
        update("ac", tool: "Bash", detail: "x", toolComplete: false)   // 工具开始(Pre)
        XCTAssertEqual(s("ac")?.toolComplete, false)
        update("ac", tool: "Bash", detail: "x", toolComplete: true)    // 工具完成(Post)→ ✓
        XCTAssertEqual(s("ac")?.toolComplete, true)
        XCTAssertEqual(s("ac")?.status, .working)                        // ✓ 不改 status,仍 working
        XCTAssertTrue(blocking)                                          // 仍阻止休眠
        update("ac")                                                     // 纯元数据(无 tool/reply)→ 不写 activity → 不清 ✓
        XCTAssertEqual(s("ac")?.toolComplete, true)
        start("ac", prompt: "new turn")                                  // 新 turn → 清零
        XCTAssertEqual(s("ac")?.toolComplete, false)
    }

    /// toolFailed(工具失败 ✗):置位 + 记原因/失败仍 working(非终态)/下个动作覆盖旧 ✗/新 turn 清零。
    func testToolFailedLifecycle() {
        update("af", tool: "Bash", detail: "npm test", toolComplete: true, toolFailed: true, toolError: "exit 1")
        XCTAssertEqual(s("af")?.toolFailed, true)
        XCTAssertEqual(s("af")?.toolError, "exit 1")
        XCTAssertEqual(s("af")?.status, .working)                        // 工具失败不是终态,仍 working
        XCTAssertTrue(blocking)                                          // 仍阻止休眠
        update("af", tool: "Edit", detail: "a.swift", toolComplete: true) // 下个动作成功 → ✗ 与原因都被覆盖清掉
        XCTAssertEqual(s("af")?.toolFailed, false)
        XCTAssertNil(s("af")?.toolError)
        XCTAssertEqual(s("af")?.toolComplete, true)
        update("af", tool: "Bash", detail: "y", toolComplete: true, toolFailed: true, toolError: "boom")
        start("af", prompt: "new turn")                                  // 新 turn → 清零失败标记/原因
        XCTAssertEqual(s("af")?.toolFailed, false)
        XCTAssertNil(s("af")?.toolError)
    }

    // MARK: - 子任务 / 移除

    func testSubtaskFields() {
        start("P#a1", parentId: "P", name: "Explore")
        XCTAssertEqual(s("P#a1")?.parentId, "P")
        XCTAssertEqual(s("P#a1")?.name, "Explore")
        XCTAssertTrue(s("P#a1")?.isSubtask ?? false)
    }

    func testRemoveCascadesChildren() {
        start("P")
        start("P#c", parentId: "P", name: "sub")
        store.remove(id: "P")
        XCTAssertNil(s("P"))
        XCTAssertNil(s("P#c"))              // 级联移除子任务
    }

    // MARK: - enrichPrompt(纯展示富化:补 prompt,不建项/不覆盖/不改状态)

    /// 子代理无 prompt 时补上;已有则不覆盖(关联器给的值优先)。
    func testEnrichPromptFillsEmptyOnly() {
        start("E#a", parentId: "E", name: "Explore")   // 子任务,无 prompt
        XCTAssertNil(s("E#a")?.prompt)
        store.enrichPrompt(id: "E#a", prompt: "找 API 端点")
        XCTAssertEqual(s("E#a")?.prompt, "找 API 端点")
        store.enrichPrompt(id: "E#a", prompt: "想覆盖")   // 已有 → 不覆盖
        XCTAssertEqual(s("E#a")?.prompt, "找 API 端点")
    }

    /// 不存在的 id 不凭空建项(避免从 background_tasks 的 subagent 条目重复建项)。
    func testEnrichPromptIgnoresAbsent() {
        store.enrichPrompt(id: "ghost", prompt: "x")
        XCTAssertNil(s("ghost"))
    }

    /// 富化已 done 的子代理:补 prompt 但**不复活**(status 仍 done,休眠不受影响)。
    func testEnrichPromptDoesNotReviveTerminal() {
        start("E2#a", parentId: "E2", name: "workflow-subagent")
        store.done(id: "E2#a", reply: "DONE")
        store.enrichPrompt(id: "E2#a", prompt: "扫描端点")
        XCTAssertEqual(s("E2#a")?.status, .done)        // 不改状态
        XCTAssertEqual(s("E2#a")?.prompt, "扫描端点")
        XCTAssertFalse(blocking)                         // 不重新阻止休眠
    }

    // MARK: - seen 生命周期

    func testSeenLifecycle() {
        start("d1")
        store.done(id: "d1", reply: nil)
        XCTAssertFalse(s("d1")?.seen ?? true)
        store.markTerminalSeen()            // 模拟打开 popover
        XCTAssertTrue(s("d1")?.seen ?? false)
        store.purgeSeenTerminal()           // 模拟关闭 popover
        XCTAssertNil(s("d1"))               // 下次打开消失
    }

    // MARK: - 排序

    func testActiveSortedBeforeTerminal() {
        start("w")
        start("t"); store.done(id: "t", reply: nil)
        let order = store.snapshotSync().map { $0.id }
        guard let iw = order.firstIndex(of: "w"), let it = order.firstIndex(of: "t") else {
            return XCTFail("缺行")
        }
        XCTAssertLessThan(iw, it)           // 活动在前,终态在后
    }

    // MARK: - 回调(主线程 async,用 expectation 等 runloop)

    func testAttentionFiresOnceOnEnterWaiting() {
        start("x")
        var count = 0
        let exp = expectation(description: "attention")
        store.onAttention = { _ in count += 1; exp.fulfill() }
        store.wait(id: "x", message: "m", parentId: nil, name: nil, agent: nil, cwd: nil)
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(count, 1)
    }

    func testTerminalAlertFiresOnEnterFailed() {
        let exp = expectation(description: "failed alert")
        store.onTerminalAlert = { session in
            XCTAssertEqual(session.status, .failed)
            exp.fulfill()
        }
        store.fail(id: "y", parentId: nil, name: nil, errorKind: "server_error",
                   errorDetail: nil, reply: nil, agent: nil, cwd: nil)
        wait(for: [exp], timeout: 2)
    }

    // MARK: - 父保留闸(有在跑子任务的父,即使已终态也不清除)

    /// 父 turn 结束置 done,但后台子项仍在跑 → ① 休眠仍阻止(子在跑);② 关 popover 不清除父(否则子变孤儿)。
    func testParentDoneWithWorkingChildIsRetainedAndBlocks() {
        start("PB")                                         // 父
        start("PB#bg:sh", parentId: "PB", name: "shell")    // 后台子项在跑
        store.done(id: "PB", reply: "turn done")            // 父 turn 结束
        XCTAssertEqual(s("PB")?.status, .done)
        XCTAssertEqual(s("PB#bg:sh")?.status, .working)
        XCTAssertTrue(blocking)                              // 子在跑 → 仍阻止休眠(核心:不漏挡)
        store.markTerminalSeen()                             // 打开 popover(父 done 标 seen)
        store.purgeSeenTerminal()                            // 关闭 popover
        XCTAssertNotNil(s("PB"))                             // 父被保留(有在跑子任务),不变孤儿
        XCTAssertNotNil(s("PB#bg:sh"))
    }

    /// 后台子项完成后,父子在下次 purge 一起清除(子全终结 → 父不再受保护)。
    func testParentClearedAfterChildDone() {
        start("PC")
        start("PC#bg:sh", parentId: "PC", name: "shell")
        store.done(id: "PC", reply: nil)
        store.done(id: "PC#bg:sh", reply: nil)              // 子(后台进程)也结束
        XCTAssertFalse(blocking)                             // 都终态 → 放行休眠
        store.markTerminalSeen()
        store.purgeSeenTerminal()
        XCTAssertNil(s("PC"))                                // 子全终结 → 父可清
        XCTAssertNil(s("PC#bg:sh"))
    }

    /// 等待中(waiting)的子任务同样保护父不被清(非终态即保护)。
    func testParentRetainedWhileChildWaiting() {
        start("PW")
        start("PW#a1", parentId: "PW", name: "Explore")
        store.wait(id: "PW#a1", message: "授权?", parentId: "PW", name: "Explore", agent: nil, cwd: nil)
        store.done(id: "PW", reply: nil)
        store.markTerminalSeen()
        store.purgeSeenTerminal()
        XCTAssertNotNil(s("PW"))                             // 子 waiting(非终态)→ 父保留
        XCTAssertEqual(s("PW#a1")?.status, .waiting)
    }
}
