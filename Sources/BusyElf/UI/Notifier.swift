import Foundation
import UserNotifications

/// 任务进入 waiting 时发系统横幅。去抖由 TaskStore 负责(只在 working→waiting 跳变回调一次)。
///
/// 注意:`UNUserNotificationCenter` 要求 app 是带 bundle id 且已签名的正经 bundle;
/// 未签名 / 命令行直跑时 add 可能失败——这里一律吞错,绝不影响核心休眠逻辑。
final class Notifier {
    static let shared = Notifier()
    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                NSLog("BusyElf: 通知授权失败: \(error)")
            }
        }
    }

    /// 用任务的 id 作通知标识 → 同一任务重复进入 waiting 只会替换而非堆叠。
    func notifyWaiting(_ session: TaskSession) {
        let content = UNMutableNotificationContent()
        content.title = "🔔 \(session.projectName)"
        if let message = session.waitingMessage, !message.isEmpty {
            content.body = message
        } else {
            content.body = "需要你处理"
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "busyelf.wait.\(session.id)",
            content: content,
            trigger: nil)   // 立即投递

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("BusyElf: 发送通知失败: \(error)")
            }
        }
    }

    /// 任务异常停止(StopFailure)→ 发紧急横幅。去抖由 TaskStore 负责(只在 →failed 跳变回调)。
    func notifyFailed(_ session: TaskSession) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ \(session.projectName) 执行失败"
        let kind = session.errorKind.map { "[\($0)] " } ?? ""
        let detail = session.errorDetail ?? session.reply ?? "agent 异常停止"
        content.body = kind + detail
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "busyelf.failed.\(session.id)",
            content: content,
            trigger: nil)

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("BusyElf: 发送失败通知失败: \(error)")
            }
        }
    }
}
