import AppKit
import UserNotifications

/// 持有 `NSStatusItem` + `NSPopover` + server 生命周期;
/// 连 `TaskStore.onChange → 刷新图标 / popover`;左键 popover / 右键菜单。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusController: StatusItemController!
    private let popover = NSPopover()
    private var popoverController: PopoverController?   // 懒加载,纯 AppKit
    private var latestSessions: [TaskSession] = []      // 给首次创建的 popover 喂初值
    private var server: LoopbackServer!
    private var serverReachable = true                  // 服务是否可达(端口冲突时 false → 菜单栏/横幅报错)

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 单元测试宿主:跳过 app 装配(不起服务端 / 不建状态栏),让测试纯跑内部逻辑。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        TaskStore.shared.setInactivityTimeout(AppConfig.shared.inactivityTimeout)   // 看门狗阈值:从配置注入
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
        // 首次打开时才建内容控制器(见 ensurePopoverContent),启动期不构建 UI。
    }

    /// 首次打开 popover 时才实例化内容控制器(纯 AppKit,不链接 SwiftUI)。
    private func ensurePopoverContent() {
        guard popoverController == nil else { return }
        let controller = PopoverController()
        controller.onRestartServer = { [weak self] in self?.server?.restart() }
        controller.listenAddressProvider = { [weak self] in
            guard let p = self?.server?.port, p != 0 else { return nil }
            return "\(AppConfig.shared.listenOnAllInterfaces ? "0.0.0.0" : "127.0.0.1"):\(p)"
        }
        controller.onLanguageChange = { [weak self] lang in self?.applyLanguage(lang) }
        // 接入配方(可扩展):每条 = 一个 harness 标签 + 现取实际端口生成的完整提示词。
        // 以后支持新 harness 就在数组里加一条;PopoverController 只按数组渲染行,不识别具体 harness。
        controller.setupRecipesProvider = { [weak self] in
            let p = self?.server?.port ?? 0
            return [
                ("Claude Code", ClaudeHookEvent.installPrompt(port: p)),
                (L.Setup.otherHarness, GenericSetupPrompt.installPrompt(port: p)),
            ]
        }
        controller.dismissPopover = { [weak self] in self?.popover.performClose(nil) }
        controller.update(sessions: latestSessions)   // 喂入当前快照
        controller.setServerUnreachable(!serverReachable)   // 反映当前可达态(可能在 popover 建立前就已不可达)
        popover.contentViewController = controller
        popoverController = controller
    }

    private func wireStore() {
        // onChange / onAttention / onTerminalAlert 均由 TaskStore 在主线程回调。
        TaskStore.shared.onChange = { [weak self] sessions in
            self?.handleStoreChange(sessions)
        }
        TaskStore.shared.onAttention = { session in
            Notifier.shared.notifyWaiting(session)
        }
        TaskStore.shared.onTerminalAlert = { session in
            Notifier.shared.notifyFailed(session)
        }
    }

    private func setUpNotifications() {
        UNUserNotificationCenter.current().delegate = self
        Notifier.shared.requestAuthorization()
    }

    private func startServer() {
        let router = Router(store: .shared)
        server = LoopbackServer(router: router)
        // 端口冲突/绑定失败 → 主线程回调:菜单栏角标变红半透明 + popover 顶部横幅报错。
        server.onReachabilityChange = { [weak self] ok in
            guard let self else { return }
            self.serverReachable = ok
            self.refreshStatus(self.latestSessions)
            self.popoverController?.setServerUnreachable(!ok)
        }
        server.start()
    }

    // MARK: - TaskStore 变更 → UI

    private func handleStoreChange(_ sessions: [TaskSession]) {
        latestSessions = sessions
        refreshStatus(sessions)
        popoverController?.update(sessions: sessions)   // 仅在已创建时刷新
    }

    /// 按最新快照重算菜单栏图标(数字 / 角标 / tooltip)。store 变更与语言切换共用。
    private func refreshStatus(_ sessions: [TaskSession]) {
        // 疑似已断(stalled)的 working 不再算"在干活":图标不显忙(与"已放行休眠"一致)。
        let now = Date()
        let timeout = AppConfig.shared.inactivityTimeout
        let working = sessions.filter {
            $0.status == .working && !$0.isStalled(asOf: now, threshold: timeout)
        }.count
        let waiting = sessions.filter { $0.status == .waiting }.count
        let badge = StatusBadge(
            hasUnseenFailed: sessions.contains { $0.status == .failed && !$0.seen },
            // 子任务完成静默:只有**顶层任务**完成才点亮菜单栏绿点(子任务完成不通知)。
            hasUnseenDone:   sessions.contains { $0.status == .done && !$0.seen && !$0.isSubtask },
            serverUnreachable: !serverReachable)
        statusController.refresh(workingCount: working, waitingCount: waiting, badge: badge)
    }

    /// 语言切换:持久化 + 立即刷新菜单栏图标 tooltip + popover(若已开着);右键菜单靠下次重建。
    private func applyLanguage(_ lang: AppConfig.Language) {
        AppConfig.shared.setLanguage(lang)
        refreshStatus(latestSessions)
        popoverController?.rebuildForLanguageChange()
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
        menu.addItem(withTitle: L.Menu.openPanel, action: #selector(openPopoverFromMenu), keyEquivalent: "")
            .target = self

        menu.addItem(.separator())

        let displayItem = NSMenuItem(
            title: L.Footer.keepDisplayAwake, action: #selector(toggleKeepDisplayAwakeFromMenu), keyEquivalent: "")
        displayItem.target = self
        displayItem.state = SleepGuard.shared.keepsDisplayAwake ? .on : .off
        menu.addItem(displayItem)

        let loginItem = NSMenuItem(
            title: L.Footer.launchAtLogin, action: #selector(toggleLaunchAtLoginFromMenu), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        // 语言子菜单:Auto / English / 中文 互斥勾选(当前项打勾)。
        let languageItem = NSMenuItem(title: L.Menu.language, action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        let langs: [(String, AppConfig.Language)] = [
            (L.Footer.langAuto, .auto), ("English", .english), ("中文", .chinese),
        ]
        for (title, lang) in langs {
            let item = NSMenuItem(title: title, action: #selector(selectLanguageFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = AppConfig.shared.language == lang ? .on : .off
            languageMenu.addItem(item)
        }
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        menu.addItem(.separator())

        // 实际监听地址(只读,action=nil → 自动置灰显示);未就绪显示提示。
        let addr: String
        if let p = server?.port, p != 0 {
            let host = AppConfig.shared.listenOnAllInterfaces ? "0.0.0.0" : "127.0.0.1"
            addr = L.Menu.listening(host: host, port: p)
        } else {
            addr = L.Menu.notReady
        }
        menu.addItem(NSMenuItem(title: addr, action: nil, keyEquivalent: ""))

        let listenAllItem = NSMenuItem(
            title: L.Footer.listenAll, action: #selector(toggleListenAllFromMenu), keyEquivalent: "")
        listenAllItem.target = self
        listenAllItem.state = AppConfig.shared.listenOnAllInterfaces ? .on : .off
        listenAllItem.toolTip = L.Menu.listenAllTip
        menu.addItem(listenAllItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: L.Menu.about, action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: L.Menu.quit, action: #selector(quit), keyEquivalent: "q")
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

    @objc private func toggleListenAllFromMenu() {
        // 切换并持久化,然后热重启监听让新网口配置生效。
        AppConfig.shared.setListenOnAllInterfaces(!AppConfig.shared.listenOnAllInterfaces)
        server?.restart()
    }

    @objc private func selectLanguageFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = AppConfig.Language(rawValue: raw) else { return }
        applyLanguage(lang)
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
