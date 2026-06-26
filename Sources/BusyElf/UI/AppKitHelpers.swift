import AppKit

/// 纯 AppKit popover 用的小控件 / 工厂,避免链接 SwiftUI(省内存)。

/// 状态点:一个着色小圆。
final class DotView: NSView {
    var color: NSColor = .systemGreen {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = color.cgColor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }
}

/// hover 才变红的安静按钮(强制结束的 ×)。
final class HoverButton: NSButton {
    var normalTint: NSColor = .tertiaryLabelColor { didSet { contentTintColor = normalTint } }
    var hoverTint: NSColor = .systemRed
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) { contentTintColor = hoverTint }
    override func mouseExited(with event: NSEvent) { contentTintColor = normalTint }
}

/// 带 hover 高亮背景的行(菜单项观感)。内容加在 highlight 之上。
class HoverRow: NSView {
    private let highlightView = NSView()
    var hoverEnabled = true { didSet { refreshHighlight() } }
    private(set) var hovering = false
    private var trackingAreaRef: NSTrackingArea?

    init(hoverInset: CGFloat = 8) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)
        NSLayoutConstraint.activate([
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hoverInset),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -hoverInset),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; refreshHighlight() }
    override func mouseExited(with event: NSEvent) { hovering = false; refreshHighlight() }

    private func refreshHighlight() {
        let on = hovering && hoverEnabled
        highlightView.layer?.backgroundColor = on
            ? NSColor.unemphasizedSelectedContentBackgroundColor.cgColor
            : NSColor.clear.cgColor
    }
}

/// 整行可点的 HoverRow:label/空白处点击都算点中本行,但放过 NSSwitch / 内嵌按钮自行处理。
final class ClickableRow: HoverRow {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit is NSSwitch || (hit is NSButton && hit !== self) { return hit }
        return self
    }
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }
}

enum UI {
    /// 文本 label(不可编辑、无边框、透明)。
    static func label(_ string: String = "",
                      size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      truncates: Bool = true) -> NSTextField {
        let f = NSTextField(labelWithString: string)
        f.font = .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = truncates ? .byTruncatingTail : .byWordWrapping
        f.maximumNumberOfLines = truncates ? 1 : 0
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    /// SF Symbol 图(template,自动适配深浅色)。
    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight.symbolWeight)
        return img?.withSymbolConfiguration(cfg)
    }

    /// 一条 1px 分隔线。
    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// 撑开剩余空间的弹性占位(水平方向)。
    static func hSpacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }
}

private extension NSFont.Weight {
    /// NSFont.Weight → SF Symbol 权重的粗略映射。
    var symbolWeight: NSFont.Weight { self }
}
