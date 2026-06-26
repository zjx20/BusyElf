import Foundation
import ServiceManagement

/// 开机启动开关,基于 `SMAppService.mainApp`。默认关。
///
/// 注意:`SMAppService` 需要 app 是已签名 / 正经安装的 bundle;开发期未签名直跑时
/// register 可能抛错——这里吞错并返回当前状态,不影响其它功能。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("BusyElf: 切换开机启动失败: \(error)")
            return false
        }
    }
}
