import AppKit
import SwiftUI
import UserNotifications

/// 持有 `NSStatusItem` + `NSPopover` + server 生命周期;
/// 连 `TaskStore.onChange → 刷新图标 / popover`;左键 popover / 右键菜单。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusController: StatusItemController!
    private let popover = NSPopover()
    private let viewModel = PopoverViewModel()
    private var server: LoopbackServer!

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()
        wireStore()
        setUpNotifications()
        startServer()

        statusController.refresh(workingCount: 0, waitingCount: 0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 进程退出 powerd 会自动回收断言;这里显式释放只是干净收尾。
        server?.stop()
        SleepGuard.shared.setBlocked(false)
    }

    // MARK: - 装配

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusController = StatusItemController(statusItem: statusItem)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setUpPopover() {
        popover.behavior = .transient        // 点外部自动关闭
        popover.animates = true
        // 不在启动时建 NSHostingController —— 那会把整套 SwiftUI 机器load进内存,
        // 抬高 idle 内存地板。改为首次打开时懒加载(见 ensurePopoverContent)。
    }

    /// 首次打开 popover 时才实例化 SwiftUI host,把 SwiftUI 的内存成本推迟到真正需要时。
    private func ensurePopoverContent() {
        guard popover.contentViewController == nil else { return }
        popover.contentViewController = NSHostingController(
            rootView: PopoverRootView(viewModel: viewModel))
    }

    private func wireStore() {
        // onChange / onAttention 均由 TaskStore 在主线程回调。
        TaskStore.shared.onChange = { [weak self] sessions in
            self?.handleStoreChange(sessions)
        }
        TaskStore.shared.onAttention = { session in
            Notifier.shared.notifyWaiting(session)
        }
    }

    private func setUpNotifications() {
        UNUserNotificationCenter.current().delegate = self
        Notifier.shared.requestAuthorization()
    }

    private func startServer() {
        let router = Router(store: .shared)
        server = LoopbackServer(router: router)
        server.start()
    }

    // MARK: - TaskStore 变更 → UI

    private func handleStoreChange(_ sessions: [TaskSession]) {
        let working = sessions.filter { $0.status == .working }.count
        let waiting = sessions.filter { $0.status == .waiting }.count
        statusController.refresh(workingCount: working, waitingCount: waiting)
        viewModel.apply(snapshot: sessions)
    }

    // MARK: - 状态栏点击:左键 popover / 右键菜单

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRight {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            ensurePopoverContent()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        // 每次弹出都重建菜单,勾选状态从真相源(SleepGuard / LoginItem)现取,故不会过期。
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(openPopoverFromMenu), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let displayItem = NSMenuItem(
            title: "也保持屏幕唤醒", action: #selector(toggleKeepDisplayAwakeFromMenu), keyEquivalent: "")
        displayItem.target = self
        displayItem.state = SleepGuard.shared.keepsDisplayAwake ? .on : .off
        menu.addItem(displayItem)

        let loginItem = NSMenuItem(
            title: "开机启动", action: #selector(toggleLaunchAtLoginFromMenu), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "关于 BusyElf", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "退出 BusyElf", action: #selector(quit), keyEquivalent: "q")
            .target = self

        // 临时挂菜单并触发弹出,弹完即清空,保证下次左键仍走 action。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.menu = nil
        }
    }

    @objc private func toggleKeepDisplayAwakeFromMenu() {
        // SleepGuard 是真相源;popover 下次 onAppear 会自动同步勾选态。
        SleepGuard.shared.setKeepDisplayAwake(!SleepGuard.shared.keepsDisplayAwake)
    }

    @objc private func toggleLaunchAtLoginFromMenu() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func openPopoverFromMenu() {
        guard let button = statusItem.button else { return }
        if !popover.isShown {
            ensurePopoverContent()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 通知点击 → 打开面板

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// app 在前台时也展示横幅(否则前台收到的通知会被静默丢弃)。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// 点横幅 → 打开 popover。
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.openPopoverFromMenu()
        }
        completionHandler()
    }
}
