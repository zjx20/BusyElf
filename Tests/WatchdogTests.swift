import XCTest
@testable import BusyElf

/// 白盒:看门狗派生谓词(无活动超时 → 不再阻止休眠)。纯函数,喂构造的 lastSeen,无需 timer/sleep。
final class WatchdogTests: XCTestCase {
    private func mk(_ status: TaskStatus, lastSeenAgo: TimeInterval, now: Date) -> TaskSession {
        TaskSession(id: "x", agent: nil, cwd: nil, name: "", activity: "",
                    waitingMessage: nil, status: status,
                    startedAt: now.addingTimeInterval(-lastSeenAgo),
                    lastSeen: now.addingTimeInterval(-lastSeenAgo))
    }

    func testIsStalledOnlyWhenWorkingAndOverThreshold() {
        let now = Date()
        XCTAssertFalse(mk(.working, lastSeenAgo: 10, now: now).isStalled(asOf: now, threshold: 60))
        XCTAssertTrue(mk(.working, lastSeenAgo: 120, now: now).isStalled(asOf: now, threshold: 60))
        XCTAssertFalse(mk(.waiting, lastSeenAgo: 120, now: now).isStalled(asOf: now, threshold: 60)) // 仅 working
        XCTAssertFalse(mk(.done, lastSeenAgo: 999, now: now).isStalled(asOf: now, threshold: 60))
        XCTAssertFalse(mk(.failed, lastSeenAgo: 999, now: now).isStalled(asOf: now, threshold: 60))
    }

    func testHasBlockingWorkingExcludesStalled() {
        let now = Date()
        let fresh = mk(.working, lastSeenAgo: 5, now: now)
        let stale = mk(.working, lastSeenAgo: 120, now: now)
        let waiting = mk(.waiting, lastSeenAgo: 1, now: now)
        XCTAssertTrue(TaskStore.hasBlockingWorking([fresh], asOf: now, timeout: 60))
        XCTAssertFalse(TaskStore.hasBlockingWorking([stale], asOf: now, timeout: 60))          // 疑似已断 → 放行
        XCTAssertTrue(TaskStore.hasBlockingWorking([fresh, stale], asOf: now, timeout: 60))    // 任一活跃即阻塞
        XCTAssertFalse(TaskStore.hasBlockingWorking([stale, waiting], asOf: now, timeout: 60)) // 都不阻塞
        XCTAssertFalse(TaskStore.hasBlockingWorking([], asOf: now, timeout: 60))
    }
}
