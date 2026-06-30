import XCTest
@testable import BusyElf

/// 白盒:任务行"锚点行文本"的退化逻辑(纯函数,UI 渲染本身无法走 /debug/state 断言)。
///
/// 锚点行优先显示用户 prompt;**无 prompt 的任务**(典型:workflow 子代理,其 prompt/label 不在 hook 数据里)
/// 在非 working 态退化到 activity(它做过的活),让 done/failed/waiting 态仍看得出"做了什么"。
final class AgentRowViewTests: XCTestCase {

    private func anchor(_ prompt: String?, _ activity: String, _ status: TaskStatus) -> String? {
        AgentRowView.anchorText(prompt: prompt, activity: activity, status: status)
    }

    /// 有 prompt:任何状态都优先显示 prompt(不被 activity 顶替)。
    func testPromptPreferredInAllStates() {
        XCTAssertEqual(anchor("修 bug", "Bash: ls", .working), "修 bug")
        XCTAssertEqual(anchor("修 bug", "Bash: ls", .done), "修 bug")
        XCTAssertEqual(anchor("修 bug", "", .failed), "修 bug")
    }

    /// 无 prompt + working:不退化(此时 activity 已在主信息行实时显示,避免上下两行重复)。
    func testNoPromptWorkingDoesNotFallBack() {
        XCTAssertNil(anchor(nil, "Bash: echo hi", .working))
        XCTAssertNil(anchor("", "Bash: echo hi", .working))
    }

    /// 无 prompt + 非 working(done/failed/waiting):退化到 activity(做过的活)——核心:workflow 子代理 done 态可见工作。
    func testNoPromptTerminalFallsBackToActivity() {
        XCTAssertEqual(anchor(nil, "Bash: echo BUSYELF_PROBE_OK", .done), "Bash: echo BUSYELF_PROBE_OK")
        XCTAssertEqual(anchor(nil, "Grep: foo", .failed), "Grep: foo")
        XCTAssertEqual(anchor(nil, "Read: a.swift", .waiting), "Read: a.swift")
    }

    /// 无 prompt 且 activity 也空:整行折叠(返回 nil)。
    func testNoPromptNoActivityHidden() {
        XCTAssertNil(anchor(nil, "", .done))
        XCTAssertNil(anchor(nil, "   ", .done))
        XCTAssertNil(anchor(nil, "", .working))
    }

    /// 纯空白 prompt 视为无 prompt(退化逻辑生效)。
    func testWhitespacePromptTreatedAsEmpty() {
        XCTAssertEqual(anchor("  ", "Bash: x", .done), "Bash: x")
    }
}
