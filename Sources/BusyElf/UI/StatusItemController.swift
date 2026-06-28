import AppKit

/// 菜单栏角标聚合:有未看失败 → 红点(优先);否则有未看完成 → 绿点;否则无。
struct StatusBadge {
    var hasUnseenFailed: Bool = false
    var hasUnseenDone: Bool = false
    /// 角标颜色:红优先于绿。
    var dotColor: NSColor? {
        if hasUnseenFailed { return .systemRed }
        if hasUnseenDone { return .systemGreen }
        return nil
    }
}

/// 维护菜单栏图标外观。单一 `bolt.fill`,只靠明暗 / 数字 / 着色 / 角标变化传达状态,
/// 绝不替换字形(换字形会改宽度、让菜单栏抖动)。
///
/// 着色策略:
/// - 无 waiting:用 **template** 图(`isTemplate=true`),由系统按菜单栏明暗自动渲染成黑/白。
/// - 有 waiting:换成 **palette 着橙**的非 template 图 + 橙色数字。
/// - 有未看终态:在底图右上角合成一个小角标(红=失败 / 绿=完成),`isTemplate=false`。
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    private lazy var templateBolt: NSImage? = {
        let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BusyElf")
        let img = base?.withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        img?.isTemplate = true
        return img
    }()

    private lazy var orangeBolt: NSImage? = {
        let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BusyElf")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.systemOrange]))
        let img = base?.withSymbolConfiguration(cfg)
        img?.isTemplate = false   // 颜色已烤进图,不让系统当模板重染
        return img
    }()

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        configure()
    }

    private func configure() {
        guard let button = statusItem.button else { return }
        button.image = templateBolt
        button.imagePosition = .imageLeading           // 图标在左、数字在右
        button.imageHugsTitle = true                   // 图标紧贴数字,缩小图文间距
        button.font = font
    }

    /// 由 AppDelegate 在 TaskStore.onChange 时调用。
    /// - workingCount: 在干活的任务数(决定是否阻止休眠 / 菜单栏数字)。
    /// - waitingCount: 等用户的任务数(决定是否着关注橙 / 数字)。
    /// - badge: 终态角标(红=有未看失败,绿=有未看完成)。
    func refresh(workingCount: Int, waitingCount: Int, badge: StatusBadge = StatusBadge()) {
        guard let button = statusItem.button else { return }
        let total = workingCount + waitingCount
        let hasWaiting = waitingCount > 0
        let dotColor = badge.dotColor

        // 空闲:无活动任务且无角标 → 半透明、无数字、template(随明暗自适配)。
        if total == 0 && dotColor == nil {
            button.image = templateBolt
            button.contentTintColor = nil
            button.title = ""
            button.alphaValue = 0.45
            button.toolTip = "BusyElf · 空闲,允许休眠"
            return
        }

        button.alphaValue = 1.0
        button.contentTintColor = nil
        button.toolTip = Self.tooltip(working: workingCount, waiting: waitingCount, badge: badge)

        let useOrange = hasWaiting
        let base = useOrange ? orangeBolt : templateBolt
        if let dotColor {
            button.image = badgedBolt(base: base, templateBase: !useOrange,
                                      dot: dotColor, appearance: button.effectiveAppearance)
        } else {
            button.image = base
        }

        // 数字 = 活动任务数;只有终态项(total==0,但有角标)时不显示数字。
        if total == 0 {
            button.title = ""
        } else {
            let display = total > 9 ? "9+" : "\(total)"
            if hasWaiting {
                button.attributedTitle = NSAttributedString(
                    string: display,
                    attributes: [.foregroundColor: NSColor.systemOrange, .font: font])
            } else {
                button.title = display
            }
        }
    }

    /// 在底图右上角合成一个小角标(带一圈背景色细环,防止压在 bolt 上糊掉)。
    /// template 底图按当前菜单栏明暗烤成黑/白(合成图 isTemplate=false,失去自动明暗,故每次按外观重画)。
    private func badgedBolt(base: NSImage?, templateBase: Bool, dot: NSColor, appearance: NSAppearance) -> NSImage? {
        guard let base else { return nil }
        let pad: CGFloat = 3   // 右上角留给角标的余量
        let size = NSSize(width: base.size.width + pad, height: base.size.height + pad)
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        let img = NSImage(size: size, flipped: false) { _ in
            let boltRect = NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height)
            base.draw(in: boltRect)
            if templateBase {
                // template 默认画成黑;用 sourceAtop 染成菜单栏文字色。
                (isDark ? NSColor.white : NSColor.black).set()
                boltRect.fill(using: .sourceAtop)
            }
            let d: CGFloat = 5
            let dotRect = NSRect(x: size.width - d, y: size.height - d, width: d, height: d)
            (isDark ? NSColor.black : NSColor.white).setFill()
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1, dy: -1)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func tooltip(working: Int, waiting: Int, badge: StatusBadge) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) 个在干活(阻止休眠)") }
        if waiting > 0 { parts.append("\(waiting) 个等你处理") }
        if badge.hasUnseenFailed { parts.append("有失败,点开查看") }
        else if badge.hasUnseenDone { parts.append("有完成,点开查看") }
        if parts.isEmpty { return "BusyElf" }
        return "BusyElf · " + parts.joined(separator: " · ")
    }
}
