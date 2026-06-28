import XCTest
@testable import BusyElf

/// 白盒:两段接入提示词(Claude 专用 / 通用中立)的内容与端口替换、中立性。
final class SetupPromptTests: XCTestCase {

    func testClaudeInstallPromptContainsPortAndAllEvents() {
        let p = ClaudeHookEvent.installPrompt(port: 19001)
        XCTAssertTrue(p.contains("http://127.0.0.1:19001/claude/hooks"))   // 端口已替换好
        XCTAssertTrue(p.contains("type"))                                  // 原生 http hook 块
        XCTAssertTrue(p.contains("settings.json"))                         // 用户级合并目标
        XCTAssertTrue(p.contains("settings.local.json"))                   // 项目级安装可选项
        XCTAssertTrue(p.contains("backup") || p.contains("busyelf-backup"))// 先备份
        XCTAssertTrue(p.contains("busyelf-setup-test"))                    // verify 用一次性测试任务
        for ev in ClaudeHookEvent.hookEvents {                             // 12 个事件全在
            XCTAssertTrue(p.contains(ev), "缺事件 \(ev)")
        }
    }

    func testGenericInstallPromptIsNeutral() {
        let p = GenericSetupPrompt.installPrompt(port: 19002)
        XCTAssertTrue(p.contains("http://127.0.0.1:19002/v1/task"))        // 中立端点 + 端口
        for verb in ["start", "update", "wait", "done", "fail", "remove"] {
            XCTAssertTrue(p.contains("/v1/task/\(verb)"), "缺动词 \(verb)")
        }
        XCTAssertTrue(p.contains("id"))                                    // id 必填说明
        // 中立性:不得出现任何 Claude/Anthropic 字样
        XCTAssertFalse(p.lowercased().contains("claude"))
        XCTAssertFalse(p.lowercased().contains("anthropic"))
    }
}
