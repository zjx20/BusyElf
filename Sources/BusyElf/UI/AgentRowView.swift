import AppKit

/// 单任务行(纯 AppKit)。点 × 后,× **原地**换成"取消 / 确认移除"两个无边框按钮——
/// 鼠标无需移动即可点确认;且全程在同一行内,行高几乎不变,不会出现"确认按钮被裁"。
/// 行对象按 id 复用,故确认态在快照刷新间得以保留。继承 HoverRow 获得悬停高亮。
///
/// 四态(working/waiting/done/failed)共用同一三段竖排骨架,靠状态点颜色 + 文本色 + 文案区分。
/// 子任务(parentId != nil)整行左缩进,标题前缀 "↳",标题用子任务标签(name,如 "Explore")。
final class AgentRowView: HoverRow {
    let id: String
    private var session: TaskSession
    private var now: Date
    private let isSubtask: Bool
    var onForceStop: (() -> Void)?

    private let dot = DotView()
    private let checkView = NSImageView()   // done 态:绿色 ✓(替代圆点,一眼看出已完成)
    private let subtaskArrow = UI.label("↳", size: 12, color: .secondaryLabelColor)
    private let titleLabel = UI.label(size: 13, weight: .semibold)
    private let promptLabel = UI.label(size: 12, weight: .medium)   // 用户输入:主色、中等字重、1 行截断;跨状态常驻,区分同项目多 harness 的锚点
    private let errorBadge = UI.label(size: 10, weight: .semibold, color: .systemRed)
    private let stuckIcon = NSImageView()
    private let xButton = HoverButton()
    private let secondLabel = UI.label(size: 12, color: .secondaryLabelColor)
    private let thirdLabel = UI.label(size: 11, color: .secondaryLabelColor)
    private lazy var contentView = makeContentView()

    // 行内确认:点 × 后 × 原地换成这两个无边框按钮(鼠标无需移动)。
    private let confirmButton = NSButton()
    private let cancelButton = NSButton()

    private var confirming = false {
        didSet {
            xButton.isHidden = confirming
            confirmButton.isHidden = !confirming
            cancelButton.isHidden = !confirming
            hoverEnabled = !confirming   // 确认时不再高亮,避免与按钮抢视觉
        }
    }

    private let topSeparator = UI.separator()

    init(session: TaskSession, now: Date) {
        self.id = session.id
        self.session = session
        self.now = now
        self.isSubtask = session.parentId != nil
        super.init(hoverInset: 8)

        let indent: CGFloat = isSubtask ? 18 : 0   // 子任务整行左缩进
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)
        addSubview(topSeparator)
        topSeparator.isHidden = true
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + indent),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        apply()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// 列表中非首行显示顶部细分隔线。
    func setShowsTopSeparator(_ shows: Bool) { topSeparator.isHidden = !shows }

    // MARK: - 外部更新

    func update(session: TaskSession, now: Date) {
        self.session = session
        self.now = now
        // 任务回到活动态(例如 waiting/done→working)时收起确认,避免误导
        if confirming, session.status == .working { confirming = false }
        apply()
        if confirming { updateConfirmAppearance() }
    }

    /// 仅刷新随时间变化的部分(时长 / 卡死 / 疑似已断),不重排。
    func refreshTime(now: Date) {
        self.now = now
        applyTimeVarying()
        if confirming { updateConfirmAppearance() }
    }

    /// working 且超过无活动阈值 → 疑似已断(看门狗已放行休眠)。
    private var stalled: Bool {
        session.isStalled(asOf: now, threshold: AppConfig.shared.inactivityTimeout)
    }

    /// 随时间变化的视觉:状态点(working 疑似已断转灰)、卡死/已断 ⚠ 图标、第三行文案。apply 与 ticker 共用。
    private func applyTimeVarying() {
        let stalled = self.stalled
        stuckIcon.isHidden = !(stalled || session.isStuck(asOf: now))
        stuckIcon.toolTip = stalled ? L.Row.stalledTip : L.Row.stuckTip
        if session.status == .working {
            dot.color = stalled ? .systemGray : .systemGreen
            dot.toolTip = stalled ? L.Row.stalledDot : L.Row.working
        }
        thirdLabel.stringValue = thirdLineText()
    }

    // MARK: - 应用 session → 视图

    private func apply() {
        let status = session.status
        let title = isSubtask ? subtaskLabel() : session.projectName

        // 状态点(done 例外:显示绿色 ✓ 而非圆点,见 statusSlot)
        switch status {
        case .working: dot.color = .systemGreen;  dot.toolTip = L.Row.working
        case .waiting: dot.color = .systemOrange; dot.toolTip = L.Row.waiting
        case .done:    dot.color = .systemGreen;  dot.toolTip = L.Row.done
        case .failed:  dot.color = .systemRed;    dot.toolTip = L.Row.failed
        }
        // done 显示 ✓、隐藏圆点;其余三态显示圆点、隐藏 ✓(行对象复用,故每次都要显式切回)
        let isDone = (status == .done)
        dot.isHidden = isDone
        checkView.isHidden = !isDone

        titleLabel.stringValue = title
        titleLabel.textColor = (status == .done) ? .secondaryLabelColor : .labelColor   // 完成项降存在感

        // 用户输入行:跨状态常驻(不随完成弱化,它是识别任务的锚点);子任务/无 prompt 整行折叠
        if let p = firstNonEmpty(session.prompt) {
            promptLabel.stringValue = Self.oneLine(p)   // 折叠换行/多空白为单行,再由配置截断
            promptLabel.toolTip = session.prompt         // tooltip 保留完整原文
            promptLabel.isHidden = false
        } else {
            promptLabel.isHidden = true                  // NSStackView 折叠隐藏的 arranged subview,无空行残留
        }

        // 失败类型小红标(仅 failed)
        if status == .failed, let kind = session.errorKind, !kind.isEmpty {
            errorBadge.stringValue = kind
            errorBadge.isHidden = false
        } else {
            errorBadge.isHidden = true
        }

        // 主信息行(全部 2 行封顶、尾部截断)
        switch status {
        case .waiting:
            let msg = firstNonEmpty(session.waitingMessage) ?? L.Row.needsYou
            setSecond(msg, color: .systemOrange, tip: session.waitingMessage)
        case .failed:
            let detail = firstNonEmpty(session.errorDetail, session.reply) ?? L.Row.failed
            setSecond(detail, color: .systemRed, tip: firstNonEmpty(session.errorDetail, session.reply))
        case .done:
            let r = firstNonEmpty(session.reply) ?? L.Row.done
            setSecond(r, color: .secondaryLabelColor, tip: session.reply)
        case .working:
            let hasAct = !session.activity.isEmpty
            let act = hasAct ? session.activity : L.Row.thinking
            // 这一步(工具调用)的标记:失败前缀 ✗(优先),完成前缀 ✓;仅标"这一步如何",任务仍 working、仍阻止休眠。
            // 工具失败是常态,不是终态(不变红、不弹横幅),只是动作行多一个 ✗。失败原因(若有)挂 tooltip。
            let shown: String
            if hasAct && session.toolFailed { shown = "✗ " + act }
            else if hasAct && session.toolComplete { shown = "✓ " + act }
            else { shown = act }
            let tip = firstNonEmpty(session.toolError).map { L.Row.toolFailedTip(session.activity, reason: $0) } ?? session.activity
            setSecond(shown, color: hasAct ? .labelColor : .secondaryLabelColor, tip: tip)
        }

        applyTimeVarying()   // 状态点(working 已断转灰)/ ⚠ 图标 / 第三行,随时间变化

        // 这些 tooltip/标题在 makeContentView 构建时写死、rebuild 不重设;在此统一重设,
        // 使语言切换(经 update→apply)也能刷新它们(行按 id 复用,不重建)。
        checkView.toolTip = L.Row.done
        subtaskArrow.toolTip = L.Row.subtaskTip
        errorBadge.toolTip = L.Row.errorKindTip
        xButton.toolTip = L.Row.removeTip
        cancelButton.title = L.Footer.cancel
    }

    private func setSecond(_ text: String, color: NSColor, tip: String?) {
        secondLabel.stringValue = Self.oneLine(text)   // 折叠换行/多空白 → 单逻辑行,再由 2 行配置截断
        secondLabel.textColor = color
        secondLabel.toolTip = tip                       // tooltip 保留完整原文(含换行)
    }

    /// 把多行/含连续空白的文本折叠成单行(换行、制表、连续空格 → 单个空格),首尾去空白。
    /// 防止多行命令/回复把行撑爆;真正的"≤2 行 + 省略号"由 secondLabel 的配置完成。
    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 子任务标题:优先 name(agentType,如 "Explore"),退化到 "子任务"。
    private func subtaskLabel() -> String {
        session.name.isEmpty ? L.Row.subtask : session.name
    }

    private func thirdLineText() -> String {
        var parts: [String] = []
        if stalled { parts.append(L.Row.stalledShort) }   // 看门狗已放行休眠;收到新进展会自动恢复
        switch session.status {
        case .done:   parts.append(L.Row.doneShort)
        case .failed: parts.append(L.Row.failedShort)
        default:      break
        }
        if let agent = session.agent, !agent.isEmpty { parts.append(agent) }
        // 时间放最末尾:它每秒刷新、宽度随字符数变(4s→10s→1m),搁前面会把后续文字整体左右推 → 抖动。
        // 末尾生长、其后无内容,前部稳定不动(配合 thirdLabel 等宽数字)。prompt 已移到专属行,不再拼这里。
        parts.append(Format.duration(session.elapsed(asOf: now)))
        return parts.joined(separator: " · ")
    }

    private func confirmWarnText() -> String {
        guard session.looksActive(asOf: now) else { return "" }
        return L.Row.activeWarn(Format.ago(session.sinceLastSeen(asOf: now)))
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for v in values { if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v } }
        return nil
    }

    // MARK: - 子视图构建

    private func makeContentView() -> NSView {
        // done 态的绿色 ✓:与圆点同槽位居中,只是字形更醒目(粗体钩)
        checkView.image = UI.symbol("checkmark", size: 11, weight: .bold)
        checkView.contentTintColor = .systemGreen
        checkView.translatesAutoresizingMaskIntoConstraints = false
        checkView.toolTip = L.Row.done
        checkView.isHidden = true
        checkView.setContentHuggingPriority(.required, for: .horizontal)

        // 状态指示槽:固定宽度,内居中放圆点(working/waiting/failed)或 ✓(done)。
        // 钩比圆点宽,走固定槽保证各行标题左缘对齐、不随状态抖动。
        dot.translatesAutoresizingMaskIntoConstraints = false
        let statusSlot = NSView()
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        statusSlot.setContentHuggingPriority(.required, for: .horizontal)
        statusSlot.addSubview(dot)
        statusSlot.addSubview(checkView)
        NSLayoutConstraint.activate([
            statusSlot.widthAnchor.constraint(equalToConstant: 14),
            statusSlot.heightAnchor.constraint(equalToConstant: 14),
            dot.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            checkView.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            checkView.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
        ])

        stuckIcon.image = UI.symbol("exclamationmark.triangle.fill", size: 10)
        stuckIcon.contentTintColor = .systemYellow
        stuckIcon.translatesAutoresizingMaskIntoConstraints = false
        stuckIcon.toolTip = L.Row.stuckTip
        stuckIcon.setContentHuggingPriority(.required, for: .horizontal)

        subtaskArrow.setContentHuggingPriority(.required, for: .horizontal)
        subtaskArrow.toolTip = L.Row.subtaskTip

        errorBadge.isHidden = true
        errorBadge.setContentHuggingPriority(.required, for: .horizontal)
        errorBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        errorBadge.toolTip = L.Row.errorKindTip

        xButton.image = UI.symbol("xmark.circle.fill", size: 13)
        xButton.isBordered = false
        xButton.bezelStyle = .regularSquare
        xButton.imagePosition = .imageOnly
        xButton.contentTintColor = xButton.normalTint
        xButton.target = self
        xButton.action = #selector(startConfirm)
        xButton.toolTip = L.Row.removeTip
        xButton.setContentHuggingPriority(.required, for: .horizontal)

        // 行内确认按钮(默认隐藏;点 × 后显示在 × 原位)。用标准小号圆角按钮,一看就是可点的按钮。
        for b in [confirmButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.isHidden = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        confirmButton.title = L.Row.confirmRemove
        confirmButton.bezelColor = .systemRed       // 红底,destructive 一目了然
        confirmButton.target = self
        confirmButton.action = #selector(doRemove)
        cancelButton.title = L.Footer.cancel
        cancelButton.target = self
        cancelButton.action = #selector(cancelConfirm)

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 主信息行:最多 2 行,溢出尾部省略号(byWordWrapping + truncatesLastVisibleLine 才是可靠的多行截断;
        // 单用 byTruncatingTail 配 maxLines>1 不生效,会被硬换行撑爆)。
        secondLabel.maximumNumberOfLines = 2
        secondLabel.lineBreakMode = .byWordWrapping
        (secondLabel.cell as? NSTextFieldCell)?.truncatesLastVisibleLine = true
        // 关键:低水平抗压 → 长内容时让步换行/截断,绝不把 popover 横向撑宽(同 titleLabel 的做法)。
        secondLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        secondLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        thirdLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        thirdLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 等宽数字:时间逐秒变化时数字列不抖(配合"时间放末尾"双保险,见 thirdLineText)。
        thirdLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

        // 用户输入行:同 secondLabel 的低水平抗压/低 hugging,长文本截断而绝不横向撑宽 popover。
        promptLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        promptLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var row1Views: [NSView] = [statusSlot]
        if isSubtask { row1Views.append(subtaskArrow) }
        // × 与确认/取消按钮都贴在尾部同一槽位:常规态只显示 ×;确认态 × 隐藏、显示"取消 确认移除"
        //(确认移除在最右,正落在原 × 处,鼠标无需移动)。
        row1Views.append(contentsOf: [titleLabel, errorBadge, stuckIcon, UI.hSpacer(), cancelButton, confirmButton, xButton])
        let row1 = NSStackView(views: row1Views)
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 6
        row1.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView(views: [row1, promptLabel, secondLabel, thirdLabel])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        // 各行都撑满容器宽度:row1 让 × 贴右,标签在右边距处截断
        for sub in [row1, promptLabel, secondLabel, thirdLabel] {
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor).isActive = true
            sub.trailingAnchor.constraint(equalTo: v.trailingAnchor).isActive = true
        }
        return v
    }

    // MARK: - 动作

    @objc private func startConfirm() {
        updateConfirmAppearance()
        confirming = true
    }
    @objc private func cancelConfirm() { confirming = false }
    @objc private func doRemove() {
        confirming = false
        onForceStop?()
    }

    /// 按"是否看起来仍活跃"调确认按钮文案/提示:活跃时加 ⚠ 前缀 + 警示 tooltip。
    private func updateConfirmAppearance() {
        let active = session.looksActive(asOf: now)
        confirmButton.title = active ? L.Row.confirmRemoveActive : L.Row.confirmRemove
        confirmButton.toolTip = active ? confirmWarnText() : L.Row.removeTip
    }
}
