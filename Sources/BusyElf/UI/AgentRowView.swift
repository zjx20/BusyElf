import AppKit

/// 单任务行(纯 AppKit)。点 × 就地翻成单段行内确认。
/// 行对象按 id 复用,故确认态在快照刷新间得以保留。继承 HoverRow 获得悬停高亮。
final class AgentRowView: HoverRow {
    let id: String
    private var session: TaskSession
    private var now: Date
    var onForceStop: (() -> Void)?

    // 常规态
    private let dot = DotView()
    private let titleLabel = UI.label(size: 13, weight: .semibold)
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
        super.init(hoverInset: 8)

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
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
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
        // 任务状态变了(例如 waiting→working)时收起确认,避免误导
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
        let waiting = session.status == .waiting
        dot.color = waiting ? .systemOrange : .systemGreen
        dot.toolTip = waiting ? "等你处理" : "在干活"
        titleLabel.stringValue = session.projectName
        confirmTitle.stringValue = session.projectName

        stuckIcon.isHidden = !session.isStuck(asOf: now)

        if waiting {
            let msg = session.waitingMessage?.isEmpty == false ? session.waitingMessage! : "需要你处理"
            secondLabel.stringValue = msg
            secondLabel.textColor = .systemOrange
            secondLabel.maximumNumberOfLines = 2
            secondLabel.toolTip = session.waitingMessage
        } else {
            let act = session.activity.isEmpty ? "在干活…" : session.activity
            secondLabel.stringValue = act
            secondLabel.textColor = session.activity.isEmpty ? .secondaryLabelColor : .labelColor
            secondLabel.maximumNumberOfLines = 1
            secondLabel.toolTip = session.activity
        }

        thirdLabel.stringValue = thirdLineText()

        let warn = confirmWarnText()
        confirmWarn.stringValue = warn
        confirmWarn.isHidden = warn.isEmpty
    }

    private func thirdLineText() -> String {
        let elapsed = Format.duration(session.elapsed(asOf: now))
        if let agent = session.agent, !agent.isEmpty { return "\(elapsed) · \(agent)" }
        return elapsed
    }

    private func confirmWarnText() -> String {
        guard session.looksActive(asOf: now) else { return "" }
        return "⚠ 该任务似乎仍在活动(\(Format.ago(session.sinceLastSeen(asOf: now)))还有进展)"
    }

    // MARK: - 子视图构建

    private func makeNormalView() -> NSView {
        stuckIcon.image = UI.symbol("exclamationmark.triangle.fill", size: 10)
        stuckIcon.contentTintColor = .systemYellow
        stuckIcon.translatesAutoresizingMaskIntoConstraints = false
        stuckIcon.toolTip = "长时间无进展,可能已卡死"
        stuckIcon.setContentHuggingPriority(.required, for: .horizontal)

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

        let row1 = NSStackView(views: [dot, titleLabel, stuckIcon, UI.hSpacer(), xButton])
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
