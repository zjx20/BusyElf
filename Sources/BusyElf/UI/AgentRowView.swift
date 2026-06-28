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
    private let subtaskArrow = UI.label("↳", size: 12, color: .secondaryLabelColor)
    private let titleLabel = UI.label(size: 13, weight: .semibold)
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
        stuckIcon.toolTip = stalled
            ? "超过无响应阈值,已放行休眠(收到新进展会自动恢复)"
            : "长时间无进展,可能已卡死"
        if session.status == .working {
            dot.color = stalled ? .systemGray : .systemGreen
            dot.toolTip = stalled ? "可能已断 · 已放行休眠" : "在干活"
        }
        thirdLabel.stringValue = thirdLineText()
    }

    // MARK: - 应用 session → 视图

    private func apply() {
        let status = session.status
        let title = isSubtask ? subtaskLabel() : session.projectName

        // 状态点
        switch status {
        case .working: dot.color = .systemGreen;  dot.toolTip = "在干活"
        case .waiting: dot.color = .systemOrange; dot.toolTip = "等你处理"
        case .done:    dot.color = .systemGreen;  dot.toolTip = "已完成"
        case .failed:  dot.color = .systemRed;    dot.toolTip = "执行失败"
        }

        titleLabel.stringValue = title
        titleLabel.textColor = (status == .done) ? .secondaryLabelColor : .labelColor   // 完成项降存在感

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
            let msg = firstNonEmpty(session.waitingMessage) ?? "需要你处理"
            setSecond(msg, color: .systemOrange, tip: session.waitingMessage)
        case .failed:
            let detail = firstNonEmpty(session.errorDetail, session.reply) ?? "执行失败"
            setSecond(detail, color: .systemRed, tip: firstNonEmpty(session.errorDetail, session.reply))
        case .done:
            let r = firstNonEmpty(session.reply) ?? "已完成"
            setSecond(r, color: .secondaryLabelColor, tip: session.reply)
        case .working:
            let hasAct = !session.activity.isEmpty
            let act = hasAct ? session.activity : "在思考…"
            // 这一步(工具调用)已完成则前缀 ✓;仅标"这一步完成",任务仍 working、仍阻止休眠。
            let shown = (hasAct && session.toolComplete) ? "✓ " + act : act
            setSecond(shown, color: hasAct ? .labelColor : .secondaryLabelColor, tip: session.activity)
        }

        applyTimeVarying()   // 状态点(working 已断转灰)/ ⚠ 图标 / 第三行,随时间变化
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
        session.name.isEmpty ? "子任务" : session.name
    }

    private func thirdLineText() -> String {
        var parts: [String] = []
        if stalled { parts.append("可能已断") }   // 看门狗已放行休眠;收到新进展会自动恢复
        switch session.status {
        case .done:   parts.append("完成")
        case .failed: parts.append("失败")
        default:      break
        }
        parts.append(Format.duration(session.elapsed(asOf: now)))
        if let agent = session.agent, !agent.isEmpty { parts.append(agent) }
        // working 态把用户提示词露在元信息行尾(折叠+截断);子任务无 prompt。
        if session.status == .working, let p = firstNonEmpty(session.prompt) {
            parts.append(Self.oneLine(p))
        }
        return parts.joined(separator: " · ")
    }

    private func confirmWarnText() -> String {
        guard session.looksActive(asOf: now) else { return "" }
        return "⚠ 该任务似乎仍在活动(\(Format.ago(session.sinceLastSeen(asOf: now)))还有进展),仍要移除?"
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for v in values { if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v } }
        return nil
    }

    // MARK: - 子视图构建

    private func makeContentView() -> NSView {
        stuckIcon.image = UI.symbol("exclamationmark.triangle.fill", size: 10)
        stuckIcon.contentTintColor = .systemYellow
        stuckIcon.translatesAutoresizingMaskIntoConstraints = false
        stuckIcon.toolTip = "长时间无进展,可能已卡死"
        stuckIcon.setContentHuggingPriority(.required, for: .horizontal)

        subtaskArrow.setContentHuggingPriority(.required, for: .horizontal)
        subtaskArrow.toolTip = "子任务(subagent)"

        errorBadge.isHidden = true
        errorBadge.setContentHuggingPriority(.required, for: .horizontal)
        errorBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        errorBadge.toolTip = "失败类型"

        xButton.image = UI.symbol("xmark.circle.fill", size: 13)
        xButton.isBordered = false
        xButton.bezelStyle = .regularSquare
        xButton.imagePosition = .imageOnly
        xButton.contentTintColor = xButton.normalTint
        xButton.target = self
        xButton.action = #selector(startConfirm)
        xButton.toolTip = "移除此任务(解除休眠阻止,不杀进程)"
        xButton.setContentHuggingPriority(.required, for: .horizontal)

        // 行内确认按钮(默认隐藏;点 × 后显示在 × 原位)。用标准小号圆角按钮,一看就是可点的按钮。
        for b in [confirmButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.isHidden = true
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        confirmButton.title = "确认移除"
        confirmButton.bezelColor = .systemRed       // 红底,destructive 一目了然
        confirmButton.target = self
        confirmButton.action = #selector(doRemove)
        cancelButton.title = "取消"
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

        var row1Views: [NSView] = [dot]
        if isSubtask { row1Views.append(subtaskArrow) }
        // × 与确认/取消按钮都贴在尾部同一槽位:常规态只显示 ×;确认态 × 隐藏、显示"取消 确认移除"
        //(确认移除在最右,正落在原 × 处,鼠标无需移动)。
        row1Views.append(contentsOf: [titleLabel, errorBadge, stuckIcon, UI.hSpacer(), cancelButton, confirmButton, xButton])
        let row1 = NSStackView(views: row1Views)
        row1.orientation = .horizontal
        row1.alignment = .centerY
        row1.spacing = 6
        row1.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView(views: [row1, secondLabel, thirdLabel])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        // 三行都撑满容器宽度:row1 让 × 贴右,标签在右边距处截断
        for sub in [row1, secondLabel, thirdLabel] {
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
        confirmButton.title = active ? "⚠ 确认移除" : "确认移除"
        confirmButton.toolTip = active ? confirmWarnText() : "移除此任务(解除休眠阻止,不杀进程)"
    }
}
