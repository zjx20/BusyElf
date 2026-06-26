import AppKit

/// 维护菜单栏图标外观。单一 `bolt.fill`,只靠明暗 / 数字 / 着色变化传达状态,
/// 绝不替换字形(换字形会改宽度、让菜单栏抖动)。
final class StatusItemController {
    private let statusItem: NSStatusItem

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        configure()
    }

    private func configure() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "BusyElf")
        image?.isTemplate = true                       // template 图自动适配深浅色菜单栏
        button.image = image
        button.imagePosition = .imageLeading           // 图标在左、数字在右
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    }

    /// 由 AppDelegate 在 TaskStore.onChange 时调用。
    /// - workingCount: 在干活的任务数(决定是否阻止休眠)。
    /// - waitingCount: 等用户的任务数(决定是否着关注色)。
    func refresh(workingCount: Int, waitingCount: Int) {
        guard let button = statusItem.button else { return }
        let total = workingCount + waitingCount
        let hasWaiting = waitingCount > 0

        if total == 0 {
            // 空闲:半透明、无数字
            button.title = ""
            button.alphaValue = 0.45
            button.contentTintColor = nil
            button.toolTip = "BusyElf · 空闲,允许休眠"
        } else {
            let display = total > 9 ? "9+" : "\(total)"
            button.title = " \(display)"
            button.alphaValue = 1.0
            // 有 waiting → 着橙色提示"去处理";否则用默认(随菜单栏明暗自适配)
            button.contentTintColor = hasWaiting ? .systemOrange : nil
            button.toolTip = Self.tooltip(working: workingCount, waiting: waitingCount)
        }
    }

    private static func tooltip(working: Int, waiting: Int) -> String {
        var parts: [String] = []
        if working > 0 { parts.append("\(working) 个在干活(阻止休眠)") }
        if waiting > 0 { parts.append("\(waiting) 个等你处理") }
        return "BusyElf · " + parts.joined(separator: " · ")
    }
}
