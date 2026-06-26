import AppKit

/// 维护菜单栏图标外观。单一 `bolt.fill`,只靠明暗 / 数字 / 着色变化传达状态,
/// 绝不替换字形(换字形会改宽度、让菜单栏抖动)。
///
/// 着色策略:
/// - 无 waiting:用 **template** 图(`isTemplate=true`),由系统按菜单栏明暗自动渲染成黑/白。
/// - 有 waiting:换成 **palette 着橙**的非 template 图 + 橙色数字 —— 因为 `contentTintColor`
///   对菜单栏 template 图在新系统上不可靠,直接把颜色烤进 symbol 图才稳。
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
    /// - workingCount: 在干活的任务数(决定是否阻止休眠)。
    /// - waitingCount: 等用户的任务数(决定是否着关注色)。
    func refresh(workingCount: Int, waitingCount: Int) {
        guard let button = statusItem.button else { return }
        let total = workingCount + waitingCount
        let hasWaiting = waitingCount > 0

        if total == 0 {
            // 空闲:半透明、无数字、template(随明暗自适配)
            button.image = templateBolt
            button.contentTintColor = nil
            button.title = ""
            button.alphaValue = 0.45
            button.toolTip = "BusyElf · 空闲,允许休眠"
            return
        }

        let display = total > 9 ? "9+" : "\(total)"
        button.alphaValue = 1.0
        button.toolTip = Self.tooltip(working: workingCount, waiting: waitingCount)

        if hasWaiting {
            // 需要关注:橙色图标 + 橙色数字(无前导空格,紧贴图标)
            button.image = orangeBolt
            button.contentTintColor = nil
            button.attributedTitle = NSAttributedString(
                string: display,
                attributes: [.foregroundColor: NSColor.systemOrange, .font: font])
        } else {
            // 在干活:template 全亮 + 默认色数字(随菜单栏明暗自适配)
            button.image = templateBolt
            button.contentTintColor = nil
            button.title = display
        }
    }

    private static func tooltip(working: Int, waiting: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) 个在干活(阻止休眠)") }
        if waiting > 0 { parts.append("\(waiting) 个等你处理") }
        return "BusyElf · " + parts.joined(separator: " · ")
    }
}
