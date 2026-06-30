import AppKit

/// 菜单栏角标聚合:服务不可达(端口冲突)→ 红(最高优先);否则有未看失败 → 红;
/// 否则有未看完成 → 绿点;否则无。红态把**整只闪电**染红(更显眼)**并**保留右上角小红点;
/// 绿态仅小绿点。服务不可达另压暗整体透明度以区别于"任务失败"。
struct StatusBadge {
    var hasUnseenFailed: Bool = false
    var hasUnseenDone: Bool = false
    /// 服务彻底不可达(端口被占用/绑定失败):应大声可见,提示用户去解决。
    var serverUnreachable: Bool = false
    /// 角标/着色颜色:不可达红 > 失败红 > 完成绿。红→整只闪电染红 + 右上角小红点;绿→仅右上角小绿点。
    var dotColor: NSColor? {
        if serverUnreachable { return .systemRed }
        if hasUnseenFailed { return .systemRed }
        if hasUnseenDone { return .systemGreen }
        return nil
    }
}

/// 维护菜单栏图标外观。单一 `bolt.fill`,只靠明暗 / 数字 / 着色 / 角标变化传达状态,
/// 绝不替换字形(换字形会改宽度、让菜单栏抖动)。
///
/// 着色策略(优先级:红 > 橙 > 常规):
/// - 失败/不可达:换成 **palette 着红**的非 template 图 + 红色数字(整只闪电染红,最响)。
/// - 有 waiting:换成 **palette 着橙**的非 template 图 + 橙色数字。
/// - 否则:用 **template** 图(`isTemplate=true`),由系统按菜单栏明暗自动渲染成黑/白。
/// - 有未看终态:在底图右上角合成一个小角标(红=失败/不可达,绿=完成),`isTemplate=false`。
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

    private lazy var redBolt: NSImage? = {
        let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BusyElf")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.systemRed]))
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
            button.toolTip = L.Tip.idle
            return
        }

        // 服务不可达时压暗整体(红闪电 + 半透明),与"任务失败红闪电(满亮)"区别开。
        button.alphaValue = badge.serverUnreachable ? 0.6 : 1.0
        button.contentTintColor = nil
        button.toolTip = Self.tooltip(working: workingCount, waiting: waitingCount, badge: badge)

        // 底图着色优先级:失败/不可达红(整只染红,最响)> 等待橙 > 常规 template。
        let isRed = dotColor == NSColor.systemRed
        let useOrange = !isRed && hasWaiting
        let base = isRed ? redBolt : (useOrange ? orangeBolt : templateBolt)
        // 有未看终态:右上角合成小角标(红=失败/不可达,绿=完成),与整只着色统一呈现。
        // 角标自带反差细环,红点压在红闪电上仍清晰可辨。
        if let dotColor {
            button.image = badgedBolt(base: base, templateBase: !useOrange && !isRed,
                                      dot: dotColor, appearance: button.effectiveAppearance)
        } else {
            button.image = base
        }

        // 数字 = 活动任务数;只有终态项(total==0,但有角标)时不显示数字。
        if total == 0 {
            button.title = ""
        } else {
            let display = total > 9 ? "9+" : "\(total)"
            let tint: NSColor? = isRed ? .systemRed : (hasWaiting ? .systemOrange : nil)
            if let tint {
                button.attributedTitle = NSAttributedString(
                    string: display,
                    attributes: [.foregroundColor: tint, .font: font])
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
        if badge.serverUnreachable { return "BusyElf · " + L.Tip.unreachable }
        var parts: [String] = []
        if working > 0 { parts.append(L.Tip.working(working)) }
        if waiting > 0 { parts.append(L.Tip.waiting(waiting)) }
        if badge.hasUnseenFailed { parts.append(L.Tip.hasFailed) }
        else if badge.hasUnseenDone { parts.append(L.Tip.hasDone) }
        if parts.isEmpty { return "BusyElf" }
        return "BusyElf · " + parts.joined(separator: " · ")
    }
}
