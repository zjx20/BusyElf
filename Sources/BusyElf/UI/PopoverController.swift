import AppKit

/// popover 内容(纯 AppKit,无 SwiftUI):状态头 → 可滚动任务列表 / 空态 → 底部开关。
/// 替代原 SwiftUI 的 PopoverRootView + PopoverViewModel,目的是不链接 SwiftUI 以压低内存。
///
/// 1s 时长 ticker 仅在 popover 可见时运行(viewWillAppear/viewDidDisappear),空闲 0 CPU。
final class PopoverController: NSViewController {
    private var sessions: [TaskSession] = []
    private var now = Date()
    private var ticker: Timer?

    private var rowsById: [String: AgentRowView] = [:]
    private var confirmingStopAll = false

    // 头部
    private let boltIcon = NSImageView()
    private let subtitleLabel = UI.label(size: 11, color: .secondaryLabelColor)

    // 内容区
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyView = PopoverController.makeEmptyView()

    // 底部
    private let stopAllContainer = NSView()
    private let displaySwitch = NSSwitch()
    private let loginSwitch = NSSwitch()

    private let contentWidth: CGFloat = 340

    // MARK: - 生命周期

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 6, right: 0)

        let header = makeHeader()
        let footer = makeFooter()
        buildList()

        for v in [header, UI.separator(), scrollView, emptyView, UI.separator(), footer] {
            root.addArrangedSubview(v)
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        root.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        now = Date()
        displaySwitch.state = SleepGuard.shared.keepsDisplayAwake ? .on : .off
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        rebuild()
        startTicker()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopTicker()
        confirmingStopAll = false
    }

    // MARK: - 外部数据入口(AppDelegate 在 onChange 时调用)

    func update(sessions: [TaskSession]) {
        self.sessions = sessions
        if isViewLoaded { rebuild() }
    }

    // MARK: - 渲染

    private func rebuild() {
        now = Date()
        let ids = Set(sessions.map { $0.id })

        // 移除消失的行
        for (id, row) in rowsById where !ids.contains(id) {
            row.removeFromSuperview()
            rowsById[id] = nil
        }
        // 新增 / 更新现有行
        for s in sessions {
            if let row = rowsById[s.id] {
                row.update(session: s, now: now)
            } else {
                let row = AgentRowView(session: s, now: now)
                let id = s.id
                row.onForceStop = { [weak self] in self?.onForceStop(id) }
                rowsById[s.id] = row
            }
        }
        // 按 session 顺序重排 stack(行对象复用,确认态得以保留)
        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (index, s) in sessions.enumerated() {
            guard let row = rowsById[s.id] else { continue }
            listStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
            row.setShowsTopSeparator(index > 0)   // 行间细分隔线(首行不画)
        }

        let empty = sessions.isEmpty
        scrollView.isHidden = empty
        emptyView.isHidden = !empty

        updateHeader()
        updateFooter()
    }

    private func updateHeader() {
        let working = sessions.lazy.filter { $0.status == .working }.count
        let waiting = sessions.lazy.filter { $0.status == .waiting }.count
        if sessions.isEmpty {
            subtitleLabel.stringValue = "Idle · 允许休眠"
            boltIcon.contentTintColor = .secondaryLabelColor
        } else if working > 0 {
            subtitleLabel.stringValue = "Blocking sleep · \(sessions.count) 个任务"
            boltIcon.contentTintColor = waiting > 0 ? .systemOrange : .labelColor
        } else {
            subtitleLabel.stringValue = "等你处理 · \(sessions.count) 个任务"
            boltIcon.contentTintColor = .systemOrange
        }
    }

    private func updateFooter() {
        stopAllContainer.subviews.forEach { $0.removeFromSuperview() }
        guard !sessions.isEmpty else { stopAllContainer.isHidden = true; return }
        stopAllContainer.isHidden = false
        let content = confirmingStopAll ? makeStopAllConfirm() : makeStopAllButton()
        stopAllContainer.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: stopAllContainer.topAnchor),
            content.bottomAnchor.constraint(equalTo: stopAllContainer.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: stopAllContainer.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: stopAllContainer.trailingAnchor),
        ])
    }

    // MARK: - ticker

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            for row in self.rowsById.values { row.refreshTime(now: self.now) }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    // MARK: - 动作

    private func onForceStop(_ id: String) { TaskStore.shared.end(id: id) }

    @objc private func toggleDisplayAwake() {
        SleepGuard.shared.setKeepDisplayAwake(displaySwitch.state == .on)
    }
    @objc private func toggleLaunchAtLogin() {
        LoginItem.setEnabled(loginSwitch.state == .on)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off   // 失败则回弹
    }
    @objc private func askStopAll() { confirmingStopAll = true; updateFooter() }
    @objc private func cancelStopAll() { confirmingStopAll = false; updateFooter() }
    @objc private func doStopAll() {
        confirmingStopAll = false
        TaskStore.shared.removeAll()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: - 视图工厂

    private func makeHeader() -> NSView {
        boltIcon.image = UI.symbol("bolt.fill", size: 15, weight: .semibold)
        boltIcon.contentTintColor = .secondaryLabelColor
        boltIcon.translatesAutoresizingMaskIntoConstraints = false
        boltIcon.setContentHuggingPriority(.required, for: .horizontal)

        let title = UI.label("BusyElf", size: 14, weight: .bold)
        let titleStack = NSStackView(views: [title, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let overflow = NSButton()
        overflow.image = UI.symbol("ellipsis", size: 13)
        overflow.isBordered = false
        overflow.imagePosition = .imageOnly
        overflow.contentTintColor = .secondaryLabelColor
        overflow.target = self
        overflow.action = #selector(showOverflowMenu(_:))
        overflow.toolTip = "更多"
        overflow.translatesAutoresizingMaskIntoConstraints = false
        overflow.setContentHuggingPriority(.required, for: .horizontal)

        // 用显式约束控制四周留白:NSStackView.edgeInsets 在此嵌套场景不生效。
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(boltIcon)
        container.addSubview(titleStack)
        container.addSubview(overflow)
        NSLayoutConstraint.activate([
            titleStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            titleStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -13),
            boltIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            boltIcon.centerYAnchor.constraint(equalTo: titleStack.centerYAnchor),
            titleStack.leadingAnchor.constraint(equalTo: boltIcon.trailingAnchor, constant: 10),
            overflow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            overflow.centerYAnchor.constraint(equalTo: titleStack.centerYAnchor),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: overflow.leadingAnchor, constant: -8),
        ])
        return container
    }

    /// ⋯ overflow 菜单(低频项):版本号 + 关于。点击弹在按钮下方,而非直接跳转。
    @objc private func showOverflowMenu(_ sender: NSButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let versionItem = NSMenuItem(title: "BusyElf \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 BusyElf", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func buildList() {
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: doc.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            listStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = doc
        doc.widthAnchor.constraint(equalTo: scrollView.widthAnchor).isActive = true

        // 高度 = 内容高度,封顶 320,超出滚动
        let fit = scrollView.heightAnchor.constraint(equalTo: doc.heightAnchor)
        fit.priority = .defaultHigh
        fit.isActive = true
        scrollView.heightAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
    }

    private func makeFooter() -> NSView {
        let displayRow = toggleRow(icon: "moon.fill", title: "也保持屏幕唤醒",
                                   sw: displaySwitch, action: #selector(toggleDisplayAwake))
        let loginRow = toggleRow(icon: "power", title: "开机启动",
                                 sw: loginSwitch, action: #selector(toggleLaunchAtLogin))

        let quitRow = clickableTextRow(title: "Quit BusyElf", trailing: "⌘Q") { [weak self] in self?.quit() }

        let footer = NSStackView(views: [stopAllContainer, displayRow, loginRow, UI.separator(), quitRow])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 0
        footer.translatesAutoresizingMaskIntoConstraints = false
        for v in footer.arrangedSubviews {
            v.leadingAnchor.constraint(equalTo: footer.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: footer.trailingAnchor).isActive = true
        }
        stopAllContainer.translatesAutoresizingMaskIntoConstraints = false
        stopAllContainer.isHidden = true
        return footer
    }

    /// 开关行:整行可点切换 + hover 高亮(点开关本体或行任意处皆可)。
    private func toggleRow(icon: String, title: String, sw: NSSwitch, action: Selector) -> NSView {
        let img = NSImageView()
        img.image = UI.symbol(icon, size: 11)
        img.contentTintColor = .secondaryLabelColor
        img.translatesAutoresizingMaskIntoConstraints = false
        img.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = UI.label(title, size: 12)
        sw.controlSize = .mini
        sw.target = self
        sw.action = action
        sw.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [img, label, UI.hSpacer(), sw])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6

        let row = ClickableRow()
        row.onClick = { [weak sw] in
            guard let sw else { return }
            sw.state = (sw.state == .on) ? .off : .on
            sw.sendAction(sw.action, to: sw.target)   // 与直接拨动开关同效
        }
        embed(content, in: row, insets: NSEdgeInsets(top: 7, left: 16, bottom: 7, right: 16))
        return row
    }

    /// 纯文本行(Quit 等):整行可点 + hover 高亮。
    private func clickableTextRow(title: String, trailing: String, onClick: @escaping () -> Void) -> ClickableRow {
        let label = UI.label(title, size: 12)
        let tip = UI.label(trailing, size: 11, color: .secondaryLabelColor)
        let content = NSStackView(views: [label, UI.hSpacer(), tip])
        content.orientation = .horizontal
        content.alignment = .centerY

        let row = ClickableRow()
        row.onClick = onClick
        embed(content, in: row, insets: NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
        return row
    }

    /// 把内容 stack 贴进 ClickableRow(留 insets)。
    private func embed(_ content: NSStackView, in row: ClickableRow, insets: NSEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: row.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -insets.right),
        ])
    }

    private func makeStopAllButton() -> NSView {
        let icon = NSImageView()
        icon.image = UI.symbol("stop.circle", size: 12)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = UI.label("全部结束 (\(sessions.count))", size: 12)
        let content = NSStackView(views: [icon, label, UI.hSpacer()])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 6

        let row = ClickableRow()
        row.onClick = { [weak self] in self?.askStopAll() }
        embed(content, in: row, insets: NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16))
        return row
    }

    private func makeStopAllConfirm() -> NSView {
        let prompt = UI.label("结束全部 \(sessions.count) 个任务?", size: 12)
        let stop = NSButton(title: "结束", target: self, action: #selector(doStopAll))
        stop.controlSize = .small
        stop.bezelColor = .systemRed
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelStopAll))
        cancel.controlSize = .small
        cancel.isBordered = false

        let row = NSStackView(views: [prompt, UI.hSpacer(), stop, cancel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        return row
    }

    private static func makeEmptyView() -> NSView {
        let hammer = NSImageView()
        hammer.image = UI.symbol("hammer.fill", size: 26)
        hammer.contentTintColor = .tertiaryLabelColor

        let l1 = UI.label("工作台是空的。", size: 13, weight: .medium)
        let l2 = UI.label("当前没有 agent 在工作。Mac 会正常 idle 休眠。", size: 11,
                          color: .secondaryLabelColor, truncates: false)
        let l3 = UI.label("(注:合上盖子仍会休眠 — 长任务请开盖接电)", size: 10,
                          color: .tertiaryLabelColor, truncates: false)
        l2.alignment = .center
        l3.alignment = .center
        [l2, l3].forEach { $0.maximumNumberOfLines = 2 }

        let stack = NSStackView(views: [hammer, l1, l2, l3])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 16, bottom: 26, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// 翻转坐标系的 document view,让滚动内容从顶部排起。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
