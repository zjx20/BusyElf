import AppKit

/// 单任务行(纯 AppKit)。点 × 就地翻成单段行内确认。
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

    // 常规态
    private let dot = DotView()
    private let subtaskArrow = UI.label("↳", size: 12, color: .secondaryLabelColor)
    private let titleLabel = UI.label(size: 13, weight: .semibold)
    private let errorBadge = UI.label(size: 10, weight: .semibold, color: .systemRed)
    private let stuckIcon = NSImageView()
    private let xButton = HoverButton()
    private let secondLabel = UI.label(size: 12, color: .secondaryLabelColor)
    private let thirdLabel = UI.label(size: 11, color: .secondaryLabelColor)
    private lazy var normalView = makeNormalView()

    // 确认态
    private let confirmTitle = UI.label(size: 13, weight: .semibold)
    private let confirmWarn = UI.label(size: 11, color: .systemOrange, truncates: false)
    private lazy var confirmView = makeConfirmView()

    private var confirming = false {
        didSet {
            normalView.isHidden = confirming
            confirmView.isHidden = !confirming
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
        let container = NSStackView(views: [normalView, confirmView])
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        addSubview(topSeparator)
        topSeparator.isHidden = true
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16 + indent),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            // 内容撑满整行宽度,× 才能贴右、不再挤左
            normalView.widthAnchor.constraint(equalTo: container.widthAnchor),
            confirmView.widthAnchor.constraint(equalTo: container.widthAnchor),
            topSeparator.topAnchor.constraint(equalTo: topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        confirmView.isHidden = true
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
    }

    /// 仅刷新随时间变化的部分(时长 / 活跃警示),不重排。
    func refreshTime(now: Date) {
        self.now = now
        thirdLabel.stringValue = thirdLineText()
        stuckIcon.isHidden = !session.isStuck(asOf: now)
        if confirming { confirmWarn.stringValue = confirmWarnText(); confirmWarn.isHidden = confirmWarnText().isEmpty }
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
        confirmTitle.stringValue = title

        // 失败类型小红标(仅 failed)
        if status == .failed, let kind = session.errorKind, !kind.isEmpty {
            errorBadge.stringValue = kind
            errorBadge.isHidden = false
        } else {
            errorBadge.isHidden = true
        }

        stuckIcon.isHidden = !session.isStuck(asOf: now)

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
            let act = session.activity.isEmpty ? "在干活…" : session.activity
            setSecond(act, color: session.activity.isEmpty ? .secondaryLabelColor : .labelColor, tip: session.activity)
        }

        thirdLabel.stringValue = thirdLineText()

        let warn = confirmWarnText()
        confirmWarn.stringValue = warn
        confirmWarn.isHidden = warn.isEmpty
    }

    private func setSecond(_ text: String, color: NSColor, tip: String?) {
        secondLabel.stringValue = text
        secondLabel.textColor = color
        secondLabel.maximumNumberOfLines = 2
        secondLabel.toolTip = tip
    }

    /// 子任务标题:优先 name(agentType,如 "Explore"),退化到 "子任务"。
    private func subtaskLabel() -> String {
        session.name.isEmpty ? "子任务" : session.name
    }

    private func thirdLineText() -> String {
        var parts: [String] = []
        switch session.status {
        case .done:   parts.append("完成")
        case .failed: parts.append("失败")
        default:      break
        }
        parts.append(Format.duration(session.elapsed(asOf: now)))
        if let agent = session.agent, !agent.isEmpty { parts.append(agent) }
        // working 态把用户提示词露在元信息行尾(截断);子任务无 prompt。
        if session.status == .working, let p = firstNonEmpty(session.prompt) {
            parts.append(p)
        }
        return parts.joined(separator: " · ")
    }

    private func confirmWarnText() -> String {
        guard session.looksActive(asOf: now) else { return "" }
        return "⚠ 该任务似乎仍在活动(\(Format.ago(session.sinceLastSeen(asOf: now)))还有进展)"
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for v in values { if let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return v } }
        return nil
    }

    // MARK: - 子视图构建

    private func makeNormalView() -> NSView {
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

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var row1Views: [NSView] = [dot]
        if isSubtask { row1Views.append(subtaskArrow) }
        row1Views.append(contentsOf: [titleLabel, errorBadge, stuckIcon, UI.hSpacer(), xButton])
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

    private func makeConfirmView() -> NSView {
        let prompt = UI.label("移除此任务,让 Mac 可以休眠?", size: 12)

        let removeButton = NSButton(title: "移除", target: self, action: #selector(doRemove))
        removeButton.controlSize = .small
        removeButton.bezelColor = .systemRed
        removeButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelConfirm))
        cancelButton.controlSize = .small
        cancelButton.isBordered = false

        let buttons = NSStackView(views: [removeButton, UI.hSpacer(), cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let v = NSStackView(views: [confirmTitle, prompt, confirmWarn, buttons])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 5
        v.translatesAutoresizingMaskIntoConstraints = false
        for sub in [confirmTitle, prompt, confirmWarn, buttons] {
            sub.leadingAnchor.constraint(equalTo: v.leadingAnchor).isActive = true
            sub.trailingAnchor.constraint(equalTo: v.trailingAnchor).isActive = true
        }
        return v
    }

    // MARK: - 动作

    @objc private func startConfirm() {
        confirmWarn.stringValue = confirmWarnText()
        confirmWarn.isHidden = confirmWarnText().isEmpty
        confirming = true
    }
    @objc private func cancelConfirm() { confirming = false }
    @objc private func doRemove() {
        confirming = false
        onForceStop?()
    }
}
