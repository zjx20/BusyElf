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
