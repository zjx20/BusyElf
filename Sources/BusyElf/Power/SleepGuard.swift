import Foundation
import IOKit.pwr_mgt

/// 包裹 IOKit 电源断言。BusyElf 全局至多持有两个断言:
///  - 系统 idle 休眠断言(== `caffeinate -i`):存在 working 任务时持有。
///  - 显示器 idle 休眠断言:仅当用户开启"保持屏幕唤醒"且正在阻止休眠时持有。
///
/// 断言绑定进程:BusyElf 一旦退出/崩溃,powerd 自动回收,绝不会把 Mac 永久钉醒。
/// 本类只是个薄壳,所有状态用 `NSLock` 保护,可从任意线程调用。
final class SleepGuard {
    static let shared = SleepGuard()

    private let lock = NSLock()
    private var systemAssertion: IOPMAssertionID = 0   // 0 == 未持有
    private var displayAssertion: IOPMAssertionID = 0

    /// 是否存在 working 任务(由 TaskStore 在 0↔1 跳变时驱动)。
    private var blocked = false
    /// 用户偏好:阻止休眠期间是否也保持屏幕唤醒。
    private var keepDisplayAwake = false

    private init() {}

    /// 由 TaskStore 在"是否存在 working 任务"变化时调用。
    func setBlocked(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard on != blocked else { return }
        blocked = on
        reconcileLocked()
    }

    /// 由 UI 开关"保持屏幕唤醒"调用。
    func setKeepDisplayAwake(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard on != keepDisplayAwake else { return }
        keepDisplayAwake = on
        reconcileLocked()
    }

    var isBlocking: Bool {
        lock.lock(); defer { lock.unlock() }
        return systemAssertion != 0
    }

    /// "保持屏幕唤醒"偏好的真相源(供 popover 与右键菜单读取,保持两处一致)。
    var keepsDisplayAwake: Bool {
        lock.lock(); defer { lock.unlock() }
        return keepDisplayAwake
    }

    // MARK: - 私有:按期望状态对齐实际持有的断言(已持锁)

    private func reconcileLocked() {
        // 系统断言:当且仅当 blocked 时持有
        if blocked, systemAssertion == 0 {
            systemAssertion = create(
                type: kIOPMAssertionTypePreventUserIdleSystemSleep,
                reason: "BusyElf: agents working")
        } else if !blocked, systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }

        // 显示器断言:当且仅当 blocked && keepDisplayAwake 时持有
        let wantDisplay = blocked && keepDisplayAwake
        if wantDisplay, displayAssertion == 0 {
            displayAssertion = create(
                type: kIOPMAssertionTypePreventUserIdleDisplaySleep,
                reason: "BusyElf: keep display awake")
        } else if !wantDisplay, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    private func create(type: String, reason: String) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),   // 255
            reason as CFString,
            &id)
        return result == kIOReturnSuccess ? id : 0
    }
}
