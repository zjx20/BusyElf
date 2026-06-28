import Foundation

/// 给"非 Claude Code"的任意 harness 的通用接入提示词(**agent 中立**)。
///
/// 只描述 BusyElf 的中立六动词协议 `/v1/task/*`,不含任何特定 agent 的字段/概念 ——
/// 与 [ClaudeHookEvent.installPrompt] 的 Claude 专属版分居两处,UI 列成两行各一个复制按钮。
/// 这条路成功率取决于该 harness 自身的 hook/回调能力与 agent 的悟性,刻意写得自解释。
enum GenericSetupPrompt {
    /// 端口现取实际值填好;端口已钉死稳定,贴进去后长期有效。
    static func installPrompt(port: UInt16) -> String {
        let base = "http://127.0.0.1:\(port)/v1/task"
        return """
        # Connect this agent/harness to BusyElf

        BusyElf is a passive macOS menubar app that blocks system sleep while an agent is working \
        and shows each task's status. It is **agent-neutral**: any tool can report to it over a tiny \
        local HTTP protocol. There is no official adapter for your harness yet, so help wire one up \
        using whatever hook / lifecycle-callback mechanism your harness supports.

        How well this works depends on your harness's capabilities — do your best to map its lifecycle \
        to the six verbs below.

        ## Protocol — six verbs
        POST JSON to `\(base)/{verb}`. Every field except `id` is optional and fault-tolerant.

        - `\(base)/start`  — a task/turn began (you are working). body: `{"id": "...", "prompt": "..."}`
        - `\(base)/update` — progress: a tool ran, or streamed reply text. body: `{"id": "...", "tool": "Bash", "detail": "...", "reply": "..."}`
        - `\(base)/wait`   — blocked on the user (permission / question). body: `{"id": "...", "message": "..."}`
        - `\(base)/done`   — finished normally. body: `{"id": "...", "reply": "final message"}`
        - `\(base)/fail`   — ended with an error. body: `{"id": "...", "errorKind": "...", "errorDetail": "..."}`
        - `\(base)/remove` — drop the task entirely. body: `{"id": "..."}`

        Field reference:
        - `id` (**required**): a stable per-session id. Same id across a session's events.
        - `name`, `parentId`: for sub-tasks/sub-agents — set `parentId` to the parent's `id` and `name` to a label.
        - `prompt`, `tool`, `detail`, `reply`, `message`, `errorKind`, `errorDetail`: all optional display fields.

        Only `start`/`update` count as "working" (block sleep); `wait`/`done`/`fail` release it.

        ## Wire it up
        Find your harness's hook/event mechanism (a settings file, a plugin, a shell callback, etc.) and \
        make it POST the matching verb on each lifecycle event. Use a short timeout and ignore failures \
        (`curl -sS -m2 ... || true`) — BusyElf is a passive observer and must never block your agent.

        ## Verify
        Run this — the menubar ⚡ should light up briefly:
        ```
        curl -sS -m2 -X POST \(base)/start -d '{"id": "busyelf-setup-test", "prompt": "hi"}'
        curl -sS -m2 -X POST \(base)/done  -d '{"id": "busyelf-setup-test"}'
        ```
        If the curl cannot connect, BusyElf is not running or is on a different port — launch it and \
        re-open this setup. Full protocol reference: see `docs/PROTOCOL.md` in the BusyElf repo.
        """
    }
}
