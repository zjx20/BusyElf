import AppKit

/// 入口:纯 AppKit,无 SwiftUI App/Scene。
/// `.accessory` 激活策略 = 无 Dock 图标 / 无主菜单(配合 Info.plist 的 LSUIElement)。
@main
enum BusyElfApp {
    /// 静态强引用:`NSApplication.delegate` 是 weak,且 ARC 可能在 run() 前释放局部变量,
    /// 用静态属性持有可确保 delegate 在整个进程生命周期内存活。
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
