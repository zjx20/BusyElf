import XCTest
@testable import BusyElf

/// 白盒:菜单栏闪电的颜色决策(`StatusItemController.decideVisual`)。纯函数,直接断言。
/// 优先级(高→低):不可达红 > 失败红 > 等待橙 > (无 working)完成绿 > 运行白 > 空闲灰。
/// 不再有右上角小圆点——闪电颜色本身即状态。
final class StatusItemTests: XCTestCase {

    private func decide(working: Int = 0, waiting: Int = 0,
                        done: Bool = false, failed: Bool = false, unreachable: Bool = false) -> BoltVisual {
        StatusItemController.decideVisual(
            workingCount: working, waitingCount: waiting,
            badge: StatusBadge(hasFailed: failed, hasUnseenDone: done, serverUnreachable: unreachable))
    }

    // MARK: - 基础六档

    func testIdleIsDimNeutralNoNumber() {
        // 完全空闲 → 灰:neutral 半透明、无数字。
        XCTAssertEqual(decide(), BoltVisual(color: .neutral, alpha: 0.45, showNumber: false))
    }

    func testWorkingIsFullNeutralWithNumber() {
        // 有任务在跑 → 白:neutral 满亮 + 数字。
        XCTAssertEqual(decide(working: 2), BoltVisual(color: .neutral, alpha: 1.0, showNumber: true))
    }

    func testWaitingIsOrange() {
        XCTAssertEqual(decide(waiting: 1), BoltVisual(color: .orange, alpha: 1.0, showNumber: true))
    }

    func testTopDoneWithNothingRunningIsGreen() {
        // 顶层完成 且 无 working → 整只绿、无数字。
        XCTAssertEqual(decide(done: true), BoltVisual(color: .green, alpha: 1.0, showNumber: false))
    }

    func testFailedIsRed() {
        XCTAssertEqual(decide(failed: true), BoltVisual(color: .red, alpha: 1.0, showNumber: false))
    }

    func testUnreachableIsDimRed() {
        // 不可达红压暗(0.6),与失败满亮红区分。
        XCTAssertEqual(decide(unreachable: true), BoltVisual(color: .red, alpha: 0.6, showNumber: false))
    }

    // MARK: - 优先级 & 门槛

    func testGreenGatedByRunningTasks() {
        // 顶层完成但仍有任务在跑(如子任务/后台进程)→ 不染绿,退化为运行白。
        XCTAssertEqual(decide(working: 1, done: true), BoltVisual(color: .neutral, alpha: 1.0, showNumber: true))
    }

    func testWaitingBeatsDone() {
        // 橙 > 绿:有待输入时即使有完成也显橙。
        XCTAssertEqual(decide(waiting: 1, done: true).color, .orange)
    }

    func testFailedBeatsWaitingAndDone() {
        // 红最高:压过橙与绿。
        XCTAssertEqual(decide(waiting: 1, done: true, failed: true).color, .red)
    }

    func testWaitingBeatsWorking() {
        // 橙 > 白:有等待即显橙,不因还有 working 退回白。
        XCTAssertEqual(decide(working: 3, waiting: 1).color, .orange)
    }

    func testUnreachableBeatsFailed() {
        // 都红,但不可达用 0.6 透明度(优先命中不可达分支)。
        XCTAssertEqual(decide(failed: true, unreachable: true).alpha, 0.6)
    }

    // MARK: - 数字显隐

    func testFailedShowsNumberOnlyWithActiveTasks() {
        // 仅一个已失败、无活动任务 → 红但不显数字;有 working 陪跑 → 显数字。
        XCTAssertFalse(decide(failed: true).showNumber)
        XCTAssertTrue(decide(working: 1, failed: true).showNumber)
    }
}
