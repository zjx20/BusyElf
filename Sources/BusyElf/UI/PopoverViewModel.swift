import SwiftUI
import Combine

/// 桥接 TaskStore 快照 → SwiftUI;并提供"仅 popover 可见时运行"的 1s 时长 ticker。
/// 空闲(popover 关闭)时无任何 timer,坐实 0 idle CPU。
///
/// 全部成员只在主线程访问:onChange 派发到主线程、SwiftUI 生命周期在主线程、
/// Timer 挂主 runloop。故无需 actor 隔离。
final class PopoverViewModel: ObservableObject {
    @Published private(set) var sessions: [TaskSession] = []
    @Published private(set) var now: Date = Date()
    @Published var keepDisplayAwake: Bool = false
    @Published var launchAtLogin: Bool = false

    private var ticker: Timer?

    // MARK: - 来自 TaskStore 的快照(始终在主线程)

    func apply(snapshot: [TaskSession]) {
        sessions = snapshot
    }

    // MARK: - 派生量

    var workingCount: Int { sessions.lazy.filter { $0.status == .working }.count }
    var waitingCount: Int { sessions.lazy.filter { $0.status == .waiting }.count }
    var isBlocking: Bool { workingCount > 0 }

    var headerSubtitle: String {
        if sessions.isEmpty { return "Idle · 允许休眠" }
        if isBlocking { return "Blocking sleep · \(sessions.count) 个任务" }
        return "等你处理 · \(sessions.count) 个任务"   // 全部 waiting:亮但允许休眠
    }

    // MARK: - 生命周期(由 PopoverRootView 的 onAppear/onDisappear 驱动)

    func onAppear() {
        now = Date()
        // 以真相源为准重新同步(右键菜单也可能改过这两个偏好)
        keepDisplayAwake = SleepGuard.shared.keepsDisplayAwake
        launchAtLogin = LoginItem.isEnabled
        // 同步一份最新快照(AppDelegate 的 onChange 也会持续推)
        TaskStore.shared.snapshot { [weak self] snap in
            self?.sessions = snap
        }
        startTicker()
    }

    func onDisappear() {
        stopTicker()
    }

    private func startTicker() {
        stopTicker()
        // 用未调度的初始化器 + 仅注册到 .common 一次:.common 含事件跟踪模式,
        // 故 popover 内滚动 / 菜单跟踪时时长仍持续刷新(scheduledTimer 默认只在 .default,会被暂停)。
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.now = Date()   // Timer 回调在主 runloop,直接刷新
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    // MARK: - 动作

    func toggleKeepDisplayAwake(_ on: Bool) {
        keepDisplayAwake = on
        SleepGuard.shared.setKeepDisplayAwake(on)
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        LoginItem.setEnabled(on)
        launchAtLogin = LoginItem.isEnabled   // 以系统实际状态为准(失败时回弹)
    }

    func forceStop(_ id: String) {
        TaskStore.shared.end(id: id)
    }

    func stopAll() {
        TaskStore.shared.removeAll()
    }
}
