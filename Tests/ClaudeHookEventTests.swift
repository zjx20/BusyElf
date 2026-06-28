import XCTest
@testable import BusyElf

/// 白盒:Claude hook 原始 payload → 中立动作/折叠 id 的纯解析逻辑。
final class ClaudeHookEventTests: XCTestCase {

    private func parse(_ json: String) -> ClaudeHookEvent? {
        ClaudeHookEvent.parse(Data(json.utf8))
    }

    func testUserPromptSubmit() {
        let e = parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/c","prompt":"hi"}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertNil(e?.parentId)
        XCTAssertEqual(e?.action, .start(prompt: "hi"))
    }

    func testSubagentStartFoldsId() {
        let e = parse(#"{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(e?.id, "s#a1")          // agent_id 折进 id
        XCTAssertEqual(e?.parentId, "s")
        XCTAssertEqual(e?.name, "Explore")
        XCTAssertEqual(e?.action, .start(prompt: nil))
    }

    func testPreToolUse() {
        // 工具即将执行 → update,toolComplete=false(进行中)。
        let e = parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertEqual(e?.action, .update(tool: "Bash", detail: "ls", reply: nil, replyAppend: false, toolComplete: false))
    }

    func testPreToolUseAskUserQuestionWaits() {
        // AskUserQuestion 阻塞等用户 → wait(不发 Notification);提示文案取第一个问题文本。
        let e = parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"要不要继续?","header":"确认"}]}}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertEqual(e?.action, .wait(message: "要不要继续?"))
    }

    func testPreToolUseAskUserQuestionFallsBackToHeader() {
        // 没有 question 字段时退化用 header。
        let e = parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"header":"选个分支"}]}}"#)
        XCTAssertEqual(e?.action, .wait(message: "选个分支"))
    }

    func testPreToolUseExitPlanModeWaits() {
        // ExitPlanMode 阻塞等批准 → wait,固定提示"等待批准计划"。
        let e = parse(#"{"hook_event_name":"PreToolUse","session_id":"s","tool_name":"ExitPlanMode","tool_input":{"plan":"第一步..."}}"#)
        XCTAssertEqual(e?.action, .wait(message: "等待批准计划"))
    }

    func testPostToolUseAskUserQuestionRevivesToWorking() {
        // 用户应答后的 PostToolUse → 普通 update(toolComplete=true),让 waiting 复活回 working。
        let e = parse(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"要不要继续?"}],"answers":{"要不要继续?":"是"}}}"#)
        XCTAssertEqual(e?.action, .update(tool: "AskUserQuestion", detail: nil, reply: nil, replyAppend: false, toolComplete: true))
    }

    func testPostToolUse() {
        // 工具执行完 → update,toolComplete=true(打 ✓)。
        let e = parse(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Bash","tool_input":{"command":"ls"}}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertEqual(e?.action, .update(tool: "Bash", detail: "ls", reply: nil, replyAppend: false, toolComplete: true))
    }

    /// 在 subagent 内触发的 PostToolUse(带 agent_id)→ 折进子任务 id。
    func testPostToolUseInSubagentFoldsId() {
        let e = parse(#"{"hook_event_name":"PostToolUse","session_id":"s","agent_id":"a1","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"foo"}}"#)
        XCTAssertEqual(e?.id, "s#a1")
        XCTAssertEqual(e?.parentId, "s")
        XCTAssertEqual(e?.action, .update(tool: "Grep", detail: "foo", reply: nil, replyAppend: false, toolComplete: true))
    }

    func testPostToolUseFailure() {
        // 工具执行失败 → update,toolComplete=true + toolFailed=true(打 ✗),error 进 toolError。仍是 working(非终态)。
        let e = parse(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Bash","tool_input":{"command":"npm test"},"error":"exit 1"}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertEqual(e?.action, .update(tool: "Bash", detail: "npm test", reply: nil, replyAppend: false,
                                          toolComplete: true, toolFailed: true, toolError: "exit 1"))
    }

    /// 失败原因缺失也安全降级:toolFailed 仍 true,toolError 为 nil。
    func testPostToolUseFailureWithoutError() {
        let e = parse(#"{"hook_event_name":"PostToolUseFailure","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"a.swift"}}"#)
        XCTAssertEqual(e?.action, .update(tool: "Edit", detail: "a.swift", reply: nil, replyAppend: false,
                                          toolComplete: true, toolFailed: true, toolError: nil))
    }

    func testMessageDisplayReplaceThenAppend() {
        let first = parse(#"{"hook_event_name":"MessageDisplay","session_id":"s","index":0,"delta":"X"}"#)
        XCTAssertEqual(first?.action, .update(tool: nil, detail: nil, reply: "X", replyAppend: false, toolComplete: false))
        let next = parse(#"{"hook_event_name":"MessageDisplay","session_id":"s","index":1,"delta":"Y"}"#)
        XCTAssertEqual(next?.action, .update(tool: nil, detail: nil, reply: "Y", replyAppend: true, toolComplete: false))
    }

    func testNotificationPermissionPromptWaits() {
        let e = parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt","message":"授权?"}"#)
        XCTAssertEqual(e?.action, .wait(message: "授权?"))
    }

    func testNotificationIdlePromptIgnored() {
        let e = parse(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"idle_prompt","message":"等下一句"}"#)
        XCTAssertEqual(e?.action, .ignore)     // idle 不产生等待项
    }

    func testStopMapsToDoneWithReply() {
        let e = parse(#"{"hook_event_name":"Stop","session_id":"s","last_assistant_message":"完成了"}"#)
        XCTAssertEqual(e?.action, .done(reply: "完成了"))
    }

    func testSubagentStopFoldsIdAndDone() {
        let e = parse(#"{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"a1","last_assistant_message":"找到 3 处"}"#)
        XCTAssertEqual(e?.id, "s#a1")
        XCTAssertEqual(e?.action, .done(reply: "找到 3 处"))
    }

    func testStopFailureMapsToFail() {
        let e = parse(#"{"hook_event_name":"StopFailure","session_id":"s","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}"#)
        XCTAssertEqual(e?.action, .fail(errorKind: "rate_limit",
                                        errorDetail: "API Error: Rate limit reached",
                                        reply: "API Error: Rate limit reached"))
    }

    func testStopFailurePrefersErrorDetails() {
        let e = parse(#"{"hook_event_name":"StopFailure","session_id":"s","error":"server_error","error_details":"500 from upstream","last_assistant_message":"x"}"#)
        XCTAssertEqual(e?.action, .fail(errorKind: "server_error", errorDetail: "500 from upstream", reply: "x"))
    }

    func testSessionEndMapsToDone() {
        let e = parse(#"{"hook_event_name":"SessionEnd","session_id":"s","reason":"exit"}"#)
        XCTAssertEqual(e?.action, .done(reply: nil))
    }

    func testUnknownEventIgnored() {
        let e = parse(#"{"hook_event_name":"SessionStart","session_id":"s"}"#)
        XCTAssertEqual(e?.action, .ignore)
    }

    func testNonJSONReturnsNil() {
        XCTAssertNil(parse("not json at all"))
        XCTAssertNil(parse(""))
    }

    func testToolDetailPicksFirstNonEmpty() {
        // file_path 优先于其它(command 不在时)
        let e = parse(#"{"hook_event_name":"PostToolUse","session_id":"s","tool_name":"Edit","tool_input":{"file_path":"a.swift"}}"#)
        XCTAssertEqual(e?.action, .update(tool: "Edit", detail: "a.swift", reply: nil, replyAppend: false, toolComplete: true))
    }
}
