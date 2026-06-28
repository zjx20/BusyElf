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
    private var listHeightConstraint: NSLayoutConstraint!   // scrollView 高度 = min(列表内容高, 320),显式承载
    private var isPopoverVisible = false                    // popover 当前是否可见(决定终态项是否即时标 seen)
    private var headerView: NSView!                         // 求和算高度用(不查整树 fittingSize)
    private var footerView: NSView!
    private var sep1: NSView!
    private var sep2: NSView!

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
        headerView = header
        footerView = footer
        sep1 = UI.separator()
        sep2 = UI.separator()

        for v in [header, sep1!, scrollView, emptyView, sep2!, footer] {
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
        isPopoverVisible = true
        displaySwitch.state = SleepGuard.shared.keepsDisplayAwake ? .on : .off
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        rebuild()   // rebuild 在可见时会 markTerminalSeen(清角标),本次仍显示这些终态项
        startTicker()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        isPopoverVisible = false
        stopTicker()
        confirmingStopAll = false
        // 关闭即清理掉已 seen 的终态项 → 下次打开就不再显示。
        TaskStore.shared.purgeSeenTerminal()
    }

    /// 布局结算后再同步一次尺寸。viewWillAppear/rebuild 期算的 fittingSize 可能是未结算的旧值,
    /// 导致 popover 撑大后缩不回(余高被根 stack 摊给表头,bolt/标题浮到中间)。
    /// `syncContentSize` 带去重(高度变化 >0.5 才设),设后触发的再次布局会收敛、不会死循环。
    override func viewDidLayout() {
        super.viewDidLayout()
        syncContentSize()
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
        // 按展示顺序重排 stack(子任务紧跟父任务;行对象复用,确认态得以保留)
        let display = displaySessions(sessions)
        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (index, s) in display.enumerated() {
            guard let row = rowsById[s.id] else { continue }
            listStack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: listStack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: listStack.trailingAnchor).isActive = true
            // 子任务行与父行视觉粘连(不画分隔线);其余非首行画。
            let childUnderParent = s.parentId != nil && ids.contains(s.parentId!)
            row.setShowsTopSeparator(index > 0 && !childUnderParent)
        }

        let empty = sessions.isEmpty
        scrollView.isHidden = empty
        emptyView.isHidden = !empty

        updateHeader()
        updateFooter()
        syncContentSize()
        // popover 可见期间出现/变为终态的项也即时标 seen(立刻清菜单栏角标),关闭时一并清理。
        // 解决"开着 popover 眼看任务变 done,关闭后绿点还在、下次打开还显示一次"。
        if isPopoverVisible { TaskStore.shared.markTerminalSeen() }
    }

    /// 展示顺序:顶层任务按原排序输出,每个父任务后紧跟它的子任务(subagent)。
    /// 孤儿子任务(父已不在快照里)当顶层处理,避免丢失。纯展示层排序,不改数据层中性。
    private func displaySessions(_ sessions: [TaskSession]) -> [TaskSession] {
        let ids = Set(sessions.map { $0.id })
        var childrenByParent: [String: [TaskSession]] = [:]
        var tops: [TaskSession] = []
        for s in sessions {
            if let pid = s.parentId, ids.contains(pid) {
                childrenByParent[pid, default: []].append(s)
            } else {
                tops.append(s)
            }
        }
        var ordered: [TaskSession] = []
        for t in tops {
            ordered.append(t)
            if let kids = childrenByParent[t.id] { ordered.append(contentsOf: kids) }
        }
        return ordered
    }

    /// 内容尺寸的唯一真相,两步、都确定,不依赖含 NSScrollView 的模糊 fittingSize:
    /// 1) 量出 `listStack`(普通 stack,布局后 frame 完全可靠)的真实高度,封顶 320,写进 scrollView 的
    ///    **显式高度约束** —— 于是 scrollView 高度是个确定常量。
    /// 2) 此时整棵树高度完全确定,`view.fittingSize` 可靠,据此设 `preferredContentSize`(NSPopover 观察它,
    ///    增/减都缩放)。带阈值去重,避免 viewDidLayout 反馈死循环。
    private func syncContentSize() {
        // 1) 布局后量 listStack 真实高度(普通 stack 的 frame,在固定 340 宽下完全可靠;它在 documentView 里,
        //    高度由内容决定、不受 scrollView 当前高度裁剪),封顶 320 写进 scrollView 的显式高度约束。
        view.layoutSubtreeIfNeeded()
        let listH = sessions.isEmpty ? 0 : min(listStack.frame.height.rounded(), 320)
        if abs(listHeightConstraint.constant - listH) > 0.5 {
            listHeightConstraint.constant = listH
        }
        // 2) **确定性求和**,不查整棵树的 view.fittingSize ——
        //    后者把隐藏的 emptyView 也算进去、且不反映 scrollView 的显式高度(实测恒为 336),是反复出 bug 的根。
        //    每一项都用各自部件的 intrinsic fittingSize(不受根 stack 拉伸影响)+ 量得的内容区高,逐项相加。
        // header/footer 用 intrinsic fittingSize(它俩可能被根 stack 拉伸,frame 不可靠);
        // 分隔线高度固定不拉伸,用布局后的 frame(NSBox 的 fittingSize 可能为 0 会低估);
        // 内容区:非空 = listH(scrollView 显式高),空 = emptyView intrinsic。
        let contentH = sessions.isEmpty ? emptyView.fittingSize.height : listH
        let total = (headerView.fittingSize.height
                     + sep1.frame.height
                     + sep2.frame.height
                     + footerView.fittingSize.height
                     + contentH
                     + 6).rounded()   // 6 = 根 stack 底部 edgeInset
        guard total > 0 else { return }
        if abs(preferredContentSize.height - total) > 0.5 || preferredContentSize.width != contentWidth {
            preferredContentSize = NSSize(width: contentWidth, height: total)
        }
    }

    private func updateHeader() {
        let working = sessions.lazy.filter { $0.status == .working }.count
        let waiting = sessions.lazy.filter { $0.status == .waiting }.count
        let failed = sessions.lazy.filter { $0.status == .failed }.count
        if sessions.isEmpty {
            subtitleLabel.stringValue = "Idle · 允许休眠"
            boltIcon.contentTintColor = .secondaryLabelColor
        } else if failed > 0 {
            subtitleLabel.stringValue = "\(failed) 个失败 · 共 \(sessions.count) 个"
            boltIcon.contentTintColor = .systemRed
        } else if working > 0 {
            subtitleLabel.stringValue = "Blocking sleep · \(sessions.count) 个任务"
            boltIcon.contentTintColor = waiting > 0 ? .systemOrange : .labelColor
        } else if waiting > 0 {
            subtitleLabel.stringValue = "等你处理 · \(sessions.count) 个任务"
            boltIcon.contentTintColor = .systemOrange
        } else {
            subtitleLabel.stringValue = "已完成 · \(sessions.count) 个任务"
            boltIcon.contentTintColor = .systemGreen
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

    private func onForceStop(_ id: String) { TaskStore.shared.remove(id: id) }

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
        // 表头永不被根 stack 拉伸:有余高时摊给可滚动列表区,而不是把 bolt/标题顶到中间。
        container.setContentHuggingPriority(.required, for: .vertical)
        container.setContentCompressionResistancePriority(.required, for: .vertical)
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

        // 高度由 syncContentSize 量出列表真实高度(封顶 320)后写入这个显式常量约束。
        // 不用 `==doc @ 高优先级` 这类模糊约束:含 NSScrollView 的 view.fittingSize 对它不可靠,
        // 正是 popover "撑大缩不回" 反复复发的根源。显式常量让整棵树高度完全确定。
        listHeightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 0)
        listHeightConstraint.isActive = true
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
