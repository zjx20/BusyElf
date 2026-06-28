import XCTest
@testable import BusyElf

/// 白盒:Claude hook 原始 payload → 中立动作/折叠 id 的纯解析逻辑。
final class ClaudeHookEventTests: XCTestCase {

    private func parse(_ json: String) -> ClaudeHookEvent? {
        ClaudeHookEvent.parse(Data(json.utf8))
    }

    private func translate(_ json: String) -> ClaudeHookEvent? {
        ClaudeHookEvent.translate(Data(json.utf8))
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

    func testPermissionRequestWaits() {
        // 真实权限弹窗走 PermissionRequest(非 Notification)→ wait;文案=需批准 工具:细节。
        let e = parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"Bash","tool_input":{"command":"python3 -c x"}}"#)
        XCTAssertEqual(e?.id, "s")
        XCTAssertEqual(e?.action, .wait(message: "需批准 Bash:python3 -c x"))
    }

    func testPermissionRequestWithoutDetail() {
        // 取不到细节也安全:只用工具名。
        let e = parse(#"{"hook_event_name":"PermissionRequest","session_id":"s","tool_name":"WebFetch","tool_input":{}}"#)
        XCTAssertEqual(e?.action, .wait(message: "需批准 WebFetch"))
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

    // MARK: - 子任务输入关联(translate,有状态;各用独立 session 防串扰)

    /// 父 PreToolUse(Agent) 的 description 暂存 → 紧接的 SubagentStart 领取为子任务输入。
    func testSubagentInputFromAgentDescription() {
        // 父即将 spawn:detail 取 description(优先于 prompt)。仍正常返回父的 update(活动显示)。
        let pre = translate(#"{"hook_event_name":"PreToolUse","session_id":"S1","tool_name":"Agent","tool_input":{"description":"找 API 端点","prompt":"Find all API endpoints in the repo","subagent_type":"Explore"}}"#)
        XCTAssertEqual(pre?.id, "S1")
        XCTAssertEqual(pre?.action, .update(tool: "Agent", detail: "找 API 端点", reply: nil, replyAppend: false, toolComplete: false))
        // SubagentStart 领取 → 子任务 start 带上 description 作为输入。
        let start = translate(#"{"hook_event_name":"SubagentStart","session_id":"S1","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(start?.id, "S1#a1")
        XCTAssertEqual(start?.parentId, "S1")
        XCTAssertEqual(start?.action, .start(prompt: "找 API 端点"))
    }

    /// description 缺失时退化用 prompt。
    func testSubagentInputFallsBackToPrompt() {
        _ = translate(#"{"hook_event_name":"PreToolUse","session_id":"S2","tool_name":"Agent","tool_input":{"prompt":"重构登录模块","subagent_type":"general-purpose"}}"#)
        let start = translate(#"{"hook_event_name":"SubagentStart","session_id":"S2","agent_id":"a1","agent_type":"general-purpose"}"#)
        XCTAssertEqual(start?.action, .start(prompt: "重构登录模块"))
    }

    /// 没有前置 PreToolUse(Agent) 时,SubagentStart 领不到 → 降级为无输入(同旧行为)。
    func testSubagentStartWithoutPendingStaysNil() {
        let start = translate(#"{"hook_event_name":"SubagentStart","session_id":"S3","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(start?.action, .start(prompt: nil))
    }

    /// 串行两个子任务按 FIFO 各领各的(实测事件流即紧邻串行)。
    func testSubagentInputFifoOrder() {
        _ = translate(#"{"hook_event_name":"PreToolUse","session_id":"S4","tool_name":"Agent","tool_input":{"description":"任务A"}}"#)
        let a = translate(#"{"hook_event_name":"SubagentStart","session_id":"S4","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(a?.action, .start(prompt: "任务A"))
        _ = translate(#"{"hook_event_name":"PreToolUse","session_id":"S4","tool_name":"Agent","tool_input":{"description":"任务B"}}"#)
        let b = translate(#"{"hook_event_name":"SubagentStart","session_id":"S4","agent_id":"a2","agent_type":"Explore"}"#)
        XCTAssertEqual(b?.action, .start(prompt: "任务B"))
    }

    /// 父 turn 结束(Stop,无 parentId)清掉残留暂存 → 后续子任务领不到(不跨 turn 串位)。
    func testParentStopClearsPendingInput() {
        _ = translate(#"{"hook_event_name":"PreToolUse","session_id":"S5","tool_name":"Agent","tool_input":{"description":"残留输入"}}"#)
        // 父 Stop:turn 边界,清队列。
        let stop = translate(#"{"hook_event_name":"Stop","session_id":"S5","last_assistant_message":"done"}"#)
        XCTAssertEqual(stop?.action, .done(reply: "done"))
        let start = translate(#"{"hook_event_name":"SubagentStart","session_id":"S5","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(start?.action, .start(prompt: nil))   // 已被清,领不到
    }

    /// 子任务自身的 done(带 parentId)不应清父会话暂存。
    func testSubagentStopDoesNotClearParentPending() {
        _ = translate(#"{"hook_event_name":"PreToolUse","session_id":"S6","tool_name":"Agent","tool_input":{"description":"给下一个子任务"}}"#)
        // 某子任务结束(带 agent_id → parentId 非空),不该误清父的暂存。
        _ = translate(#"{"hook_event_name":"SubagentStop","session_id":"S6","agent_id":"older","last_assistant_message":"x"}"#)
        let start = translate(#"{"hook_event_name":"SubagentStart","session_id":"S6","agent_id":"a1","agent_type":"Explore"}"#)
        XCTAssertEqual(start?.action, .start(prompt: "给下一个子任务"))
    }
}
