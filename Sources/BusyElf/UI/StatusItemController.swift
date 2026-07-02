import AppKit

/// 终态/异常信号聚合(喂给 `StatusItemController.decideVisual`)。
/// 注:`hasUnseenDone` 只统计**顶层任务**——子任务完成静默(不点亮菜单栏),由 AppDelegate 计算时排除。
struct StatusBadge {
    /// 只要仍保留 failed 项就为 true;失败不是一次性未读提示,看过后也持续染红直到被清理/移除。
    var hasFailed: Bool = false
    var hasUnseenDone: Bool = false
    /// 服务彻底不可达(端口被占用/绑定失败):应大声可见,提示用户去解决。
    var serverUnreachable: Bool = false
}

/// 闪电的五种颜色档。`neutral` = template 图(随菜单栏明暗自动黑/白):满亮=有任务在跑(白),压暗=完全空闲(灰)。
enum BoltColor { case red, orange, green, neutral }

/// 一次渲染的完整决定(纯数据,便于白盒单测,不碰 AppKit)。
struct BoltVisual: Equatable {
    var color: BoltColor
    var alpha: CGFloat       // 空闲灰 0.45 / 不可达红 0.6 / 其余 1.0
    var showNumber: Bool     // 是否显示活动任务数(working+waiting)
}

/// 维护菜单栏图标外观。单一 `bolt.fill`,**只靠整只闪电的颜色 + 明暗 + 数字**传达状态,
/// 绝不替换字形(换字形会改宽度、让菜单栏抖动),也**不再叠加右上角小圆点**
/// (闪电本身的颜色即状态,圆点冗余;去掉更干净)。
///
/// 着色档(优先级 高→低,见 `decideVisual`):
/// - **红**:服务不可达(半透明区分)或有失败任务 —— palette 着红非 template 图 + 红色数字(最响)。
/// - **橙**:有 waiting —— palette 着橙非 template 图 + 橙色数字。
/// - **绿**:有未看**顶层**完成 **且无任何 working 任务** —— palette 着绿非 template 图(与失败红统一 UX;
///   仍有任务在跑时不染绿,避免"看着像全好了"误导休眠)。
/// - **白**:有 working 任务 —— template 图满亮(系统按菜单栏明暗渲染黑/白)+ 默认色数字。
/// - **灰**:完全空闲 —— template 图半透明(0.45)、无数字。
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

    private lazy var greenBolt: NSImage? = {
        let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BusyElf")
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.systemGreen]))
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
    /// - badge: 终态/异常信号(红=有失败,绿=有未看完成)。
    func refresh(workingCount: Int, waitingCount: Int, badge: StatusBadge = StatusBadge()) {
        guard let button = statusItem.button else { return }
        let total = workingCount + waitingCount
        let v = Self.decideVisual(workingCount: workingCount, waitingCount: waitingCount, badge: badge)

        button.contentTintColor = nil
        button.alphaValue = v.alpha
        button.image = boltImage(for: v.color)
        // 灰(空闲)= neutral 且无数字;其余走带活动数的 tooltip。
        let isIdle = v.color == .neutral && !v.showNumber
        button.toolTip = isIdle ? L.Tip.idle
            : Self.tooltip(working: workingCount, waiting: waitingCount, badge: badge)

        // 数字 = 活动任务数(working+waiting);颜色随档:红/橙同色,白/灰默认。
        if v.showNumber {
            let display = total > 9 ? "9+" : "\(total)"
            let tint: NSColor? = v.color == .red ? .systemRed : (v.color == .orange ? .systemOrange : nil)
            if let tint {
                button.attributedTitle = NSAttributedString(
                    string: display,
                    attributes: [.foregroundColor: tint, .font: font])
            } else {
                button.title = display
            }
        } else {
            button.title = ""
        }
    }

    /// 纯决策:由任务计数 + 信号得出闪电的颜色/透明度/是否显示数字。无副作用、不碰 AppKit,便于白盒单测。
    ///
    /// 优先级(高→低,首个命中即返回):
    ///  1. 服务不可达 → 红(半透明,与失败满亮红区分)。
    ///  2. 有失败任务 → 红。
    ///  3. 有 waiting → 橙。
    ///  4. 有未看**顶层**完成 **且无任何 working** → 绿(仍有任务在跑时不染绿,避免误导休眠)。
    ///  5. 有 working → 白(neutral 满亮)。
    ///  6. 完全空闲 → 灰(neutral 半透明)。
    static func decideVisual(workingCount: Int, waitingCount: Int, badge: StatusBadge) -> BoltVisual {
        let total = workingCount + waitingCount
        if badge.serverUnreachable { return BoltVisual(color: .red, alpha: 0.6, showNumber: total > 0) }
        if badge.hasFailed         { return BoltVisual(color: .red, alpha: 1.0, showNumber: total > 0) }
        if waitingCount > 0        { return BoltVisual(color: .orange, alpha: 1.0, showNumber: true) }
        if badge.hasUnseenDone && workingCount == 0 {
            return BoltVisual(color: .green, alpha: 1.0, showNumber: false)   // 顶层完成、全部跑完 → 整只绿
        }
        if workingCount > 0        { return BoltVisual(color: .neutral, alpha: 1.0, showNumber: true) }   // 运行白
        return BoltVisual(color: .neutral, alpha: 0.45, showNumber: false)                                // 空闲灰
    }

    /// 颜色档 → 具体底图(neutral 用 template,随菜单栏明暗自适配黑/白)。
    private func boltImage(for color: BoltColor) -> NSImage? {
        switch color {
        case .red:     return redBolt
        case .orange:  return orangeBolt
        case .green:   return greenBolt
        case .neutral: return templateBolt
        }
    }

    private static func tooltip(working: Int, waiting: Int, badge: StatusBadge) -> String {
        if badge.serverUnreachable { return "BusyElf · " + L.Tip.unreachable }
        var parts: [String] = []
        if working > 0 { parts.append(L.Tip.working(working)) }
        if waiting > 0 { parts.append(L.Tip.waiting(waiting)) }
        if badge.hasFailed { parts.append(L.Tip.hasFailed) }
        else if badge.hasUnseenDone { parts.append(L.Tip.hasDone) }
        if parts.isEmpty { return "BusyElf" }
        return "BusyElf · " + parts.joined(separator: " · ")
    }
}
