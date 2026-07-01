import Foundation

/// Claude Code hook 事件 → 中立动作的**内建适配器**。
///
/// Claude Code 的 HTTP hook(`type: "http"`)会把每个 hook 事件的原始 JSON 作为 POST body
/// 直接发到 `/claude/hooks`,无需用户在 hook 配置里写 `jq` + `curl`。本类型把这份原始 payload
/// 解析成 BusyElf 中立协议里的一个动作(start/update/wait/done/fail/ignore)。
///
/// **为什么单独一个文件**:这是唯一一处"懂 Claude 字段名/事件语义"的代码——把它隔离在这里,
/// `TaskStore` / 协议核心保持 agent 中立,永不 import 任何 Claude 概念。其它 agent 仍走通用
/// 的 `/v1/task/*`。Claude 只是"一等公民",不是被特殊耦合。
///
/// 映射:
///   - `UserPromptSubmit` → start   (一个 turn 开始 = 在干活)
///   - `SubagentStart`    → start    (子任务开始;agent_id 折进 id,parentId=session_id,name=agent_type)
///   - `PreToolUse`       → update  (工具即将执行 → 即时显示"正在做的工具",toolComplete=false)
///                          例外:AskUserQuestion / ExitPlanMode 阻塞等用户交互 → wait(它们不发 Notification,只发 Pre/PostToolUse)
///   - `PostToolUse`      → update  (工具已完成 → toolComplete=true 打 ✓;也是 waiting/终态→working 的恢复信号)
///   - `PostToolUseFailure` → update (工具失败 → toolFailed=true 打 ✗;失败是常态非终态,仍 working;error 进 toolError 作 tooltip)
///   - `MessageDisplay`   → update  (助手实时回复 delta → reply,replace/append)
///   - `Notification`     → wait / ignore  (按 notification_type:permission 才 wait,idle 忽略)
///   - `PermissionRequest`→ wait    (权限弹窗出现 = 等用户批准工具;真实弹窗的可靠信号,IDE/交互模式不发 Notification)
///   - `Stop`/`SessionEnd`/`SubagentStop` → done  (turn / 会话 / 子任务正常结束)
///                          + **保活**:`Stop`/`SubagentStop` 的 `background_tasks` 里仍在运行的后台条目(不分 type)
///                            → keepAlive(刷新 `lastSeen`),防它们在父长时间无 turn 时被看门狗误放行休眠。SessionEnd 除外(drain)。
///   - `StopFailure`      → fail    (turn 因 API 错误结束:error / error_details / 错误原文)
///   - 其余事件           → ignore  (安全无副作用,容忍用户多配了 hook)
///
/// **子任务**:`agent_id`(仅在 subagent 内触发时存在)折进 `id`(`session_id#agent_id`),
/// `parentId = session_id`,`name = agent_type`(如 "Explore")。折叠只发生在本适配器内,
/// 中立层只看到一个带 `parentId` 的普通任务。
///
/// 解析容错与 [TaskEvent] 一致:任何字段缺失/类型不符都降级为 nil,绝不影响休眠逻辑
/// (逻辑只看 `hook_event_name` + `session_id`)。
struct ClaudeHookEvent {
    /// 从 hook 事件派生出的中立动作。
    enum Action: Equatable {
        case start(prompt: String?)
        case update(tool: String?, detail: String?, reply: String?, replyAppend: Bool,
                    toolComplete: Bool, toolFailed: Bool = false, toolError: String? = nil)
        case wait(message: String?)
        case done(reply: String?)
        case fail(errorKind: String?, errorDetail: String?, reply: String?)
        /// 纯展示富化:给已存在的子任务补 prompt(从 background_tasks 的 subagent description 收割)。
        /// 不建项、不改 status、不碰休眠——仅在关联器漏接时兜底点亮"它在干什么"那行。
        case enrich(prompt: String)
        /// 纯保活:某后台子项仍列在 `background_tasks` 里(= 还活着)→ 刷新其 `lastSeen`,顺延看门狗截止点。
        /// 不建项、不改 status(下游 `store.keepAlive` 只对已存在的 `working` 项生效,绝不复活终态)——
        /// 防它在父任务长时间无 turn 时被看门狗误判"疑似已断"而提前放行休眠。
        case keepAlive
        case ignore
    }

    /// Stop/SubagentStop 输入里的一条后台任务(v2.1.145+ 的 `background_tasks` 数组项)。
    /// 用于"父 turn 结束但后台进程/工作仍在跑"时识别并折叠成后台子项,持续阻止休眠。
    struct BgTask: Equatable {
        let id: String          // 后台任务注册表 id(实测 = shell 的后台句柄 / subagent 的 agent_id,跨 turn 稳定)
        let type: String?       // shell / workflow / monitor / teammate / cloud session / MCP task(subagent 已在解析时剔除)
        let status: String?     // 当前状态(实测为 "running";完成的任务直接从数组消失)
        let command: String?    // shell 命令行(仅 shell)
        let description: String? // 自由文本描述
    }

    let id: String?        // 折叠后的 task id(主=session_id,子=session_id#agent_id 或 session_id#bg:taskId)
    let parentId: String?  // 子任务=session_id,否则 nil
    let name: String?      // 子任务标签=agent_type / 后台任务 type,否则 nil
    let cwd: String?
    let action: Action
    /// 仅父会话 Stop/SessionEnd 携带:本次快照里的后台任务(已剔除 subagent)。
    /// nil=该事件无此概念 / 老版本无字段(不做差集);非 nil(含空)=注册表可达,据此差集。
    /// 用 var 仅为让 memberwise init 带默认值 nil(其它构造点无需显式传);构造后不再变。
    var backgroundTasks: [BgTask]? = nil
    /// 仅 Stop/SessionEnd/SubagentStop 携带:background_tasks 里 `type=="subagent"` 条目的 description,
    /// 键为折叠 id(`session#agentId`,与 SubagentStart 一致),值为 description。
    /// 用于**兜底富化**子代理 prompt(关联器漏接时);纯展示,与 `backgroundTasks`(折叠/差集,已剔除 subagent)互补。
    var subagentDescriptions: [String: String]? = nil
    /// 仅 Stop/SubagentStop 携带:background_tasks 里**所有仍在运行**条目(不分 type)的折叠 id,用于**保活**
    /// (刷新 `lastSeen`,续期防看门狗误放行)。与 `backgroundTasks`(剔 subagent,做折叠/差集)、`subagentDescriptions`
    /// (取 subagent 的 desc)正交:保活只回答"还活着吗",覆盖 shell/subagent/workflow 等所有 type,不建项/不改状态。
    /// SessionEnd 不设(会话收尾 = drain,不给任何后台进程续期)。
    var keepAliveIds: [String]? = nil

    /// 写进任务的来源标签,用于 UI 展示/分组。
    static let agentLabel = "claude-code"

    /// 子任务输入关联器(有状态)。子任务的输入(Agent 工具的 description/prompt)只在父会话的
    /// `PreToolUse(Agent)` 里、且**不带 `agent_id`**;`SubagentStart` 只带 `agent_id` 不带输入。
    /// 二者唯一共享键是 `session_id`,实测又是紧邻串行发出,故按 session 暂存、由 SubagentStart 领取。
    private static let correlator = SubagentInputCorrelator()

    /// 后台任务差集跟踪器(有状态):记录每会话上次 Stop 快照里"仍在运行"的后台子项 id 集,
    /// 用于判定哪些后台任务已"消失=完成"(后台进程退出无事件,只能靠差集)。仅 [translate] 单点调用。
    private static let bgTracker = BackgroundTaskTracker()

    /// 宽容解析。仅当 body 根本不是 JSON 对象时返回 nil(交由 Router 忽略),保证服务端永不因 body 崩。
    static func parse(_ data: Data) -> ClaudeHookEvent? {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return nil
        }

        let event = Self.string(dict, "hook_event_name")
        let session = Self.string(dict, "session_id")
        let agentId = Self.string(dict, "agent_id")
        let agentType = Self.string(dict, "agent_type")
        let cwd = Self.string(dict, "cwd")

        // 折叠 id:在 subagent 内触发(有 agent_id)→ 子任务 "session#agent",parentId=session。
        let id: String?
        let parentId: String?
        if let session, let a = agentId, !a.isEmpty {
            id = "\(session)#\(a)"
            parentId = session
        } else {
            id = session
            parentId = nil
        }
        let name = (agentType?.isEmpty == false) ? agentType : nil   // 子任务标签

        let action: Action
        var bg: [BgTask]? = nil   // 仅父会话 Stop/SessionEnd 设置:用于后台任务差集
        var subDescs: [String: String]? = nil   // 从 background_tasks 收割的 subagent description(折叠 id→desc)
        var keepAlive: [String]? = nil   // 仅 Stop/SubagentStop 设置:仍在运行的后台条目折叠 id(保活刷新 lastSeen)
        switch event {
        case "UserPromptSubmit":
            // `prompt` 为用户提交的文本(权威 hooks 文档确认字段名为 `prompt`)。
            action = .start(prompt: Self.string(dict, "prompt"))

        case "SubagentStart":
            // 子任务开始;标签/parentId 已在上面算好,这里无额外字段。
            action = .start(prompt: nil)

        case "PreToolUse":
            let tool = Self.string(dict, "tool_name")
            let input = dict["tool_input"] as? [String: Any]
            if tool == "AskUserQuestion" || tool == "ExitPlanMode" {
                // 这俩是"阻塞等用户交互"类工具:Claude 调用后挂起、等用户回答/批准,期间**不发任何
                // Notification**(权威文档确认,实测事件流亦零 Notification),只发 Pre/PostToolUse。
                // 若按普通工具 update→working,任务会在等用户的整段时间里卡 working → 误挡休眠、不点亮
                // "需要关注"。故把它们的 PreToolUse 翻成 wait:进 waiting + 放行休眠 + 提醒;用户应答后的
                // PostToolUse 自然走 update→working 复活(与 permission_prompt 的 wait→复活同一条成熟路径)。
                action = .wait(message: Self.blockingToolPrompt(tool: tool, input: input))
            } else {
                // 普通工具即将执行:同 PostToolUse 取工具名 + 细节,但标 toolComplete=false(进行中)。
                // 让 popover 即时显示"正在做的工具",而非 PostToolUse 那个"刚做完"的滞后画面。
                let detail = Self.toolDetail(input)
                action = .update(tool: tool, detail: detail, reply: nil, replyAppend: false, toolComplete: false)
            }

        case "PostToolUse":
            // 工具名铁实;细节按工具形状尽力取(Bash 看 command,Edit/Write/Read 看 file_path,等)。
            // 工具已执行完 → toolComplete=true(UI 打 ✓);也是 waiting/终态→working 的复活信号。
            let tool = Self.string(dict, "tool_name")
            let detail = Self.toolDetail(dict["tool_input"] as? [String: Any])
            action = .update(tool: tool, detail: detail, reply: nil, replyAppend: false, toolComplete: true)

        case "PostToolUseFailure":
            // 工具执行失败(抛错/返回失败)。字段同 PostToolUse(tool_name/tool_input)+ 顶层 `error`(失败原因)。
            // 工具失败是常态、不代表 agent loop 中断 → 仍是 update→working(非终态),只是 UI 打 ✗ 而非 ✓。
            // 失败原因塞进 toolError(仅作 activity 行 tooltip,不进可见正文,守 popover 紧凑)。
            let tool = Self.string(dict, "tool_name")
            let detail = Self.toolDetail(dict["tool_input"] as? [String: Any])
            let error = Self.string(dict, "error")
            action = .update(tool: tool, detail: detail, reply: nil, replyAppend: false,
                             toolComplete: true, toolFailed: true, toolError: error)

        case "MessageDisplay":
            // 助手文本流式输出:delta 是增量。新消息首批(index==0)替换,后续追加。
            let delta = Self.string(dict, "delta")
            let index = Self.int(dict, "index") ?? 0
            action = .update(tool: nil, detail: nil, reply: delta, replyAppend: index != 0, toolComplete: false)

        case "Notification":
            // 读 notification_type 区分:permission(真等待)才 wait;idle 等不产生等待项。
            // 注意:Notification(permission_prompt) 只在部分环境/窗口失焦时作为系统提醒发出,
            // **不是**权限弹窗的可靠信号——可靠信号是下面的 PermissionRequest。两者都通向 wait(冗余兜底)。
            let kind = Self.string(dict, "notification_type")
            if kind == "permission_prompt" || kind == "elicitation_dialog" {
                action = .wait(message: Self.string(dict, "message"))
            } else {
                action = .ignore
            }

        case "PermissionRequest":
            // 权限弹窗出现 = agent 挂起等用户批准/拒绝某个工具调用。实测:IDE / 交互模式下真实权限弹窗
            // 走的就是 PermissionRequest(带 tool_name / tool_input / permission_suggestions),而**不发**
            // Notification(permission_prompt)。故 → wait:进 waiting + 放行休眠 + 点亮关注。批准后 PostToolUse
            // → working 复活;拒绝则后续 MessageDisplay / 下一个工具 / Stop 自然接管(与 wait 的复活同一路径)。
            // BusyElf 始终回 2xx 空体 → 不返回任何 permission 决定,绝不影响权限流程(纯被动观察)。
            let tool = Self.string(dict, "tool_name")
            let detail = Self.toolDetail(dict["tool_input"] as? [String: Any])
            if let tool {
                action = .wait(message: L.Wait.approveTool(tool, detail: detail))
            } else {
                action = .wait(message: L.Wait.approveToolGeneric)
            }

        case "Stop":
            // turn 正常结束:last_assistant_message 是最终回复文本(无需解析 transcript)。
            // 同时取 background_tasks(v2.1.145+):turn 结束但仍有后台进程/工作在跑时,据此折叠成后台子项继续阻止休眠。
            action = .done(reply: Self.string(dict, "last_assistant_message"))
            bg = Self.parseBackgroundTasks(dict)   // key 不存在 → nil(老版本/注册表不可达,不做差集)
            subDescs = Self.parseSubagentDescriptions(dict, session: session)   // 兜底富化:收割在跑子代理的 description
            keepAlive = Self.parseKeepAliveIds(dict, session: session)   // 保活:仍在跑的后台条目(不分 type)刷新 lastSeen

        case "SessionEnd":
            // 整个会话结束:无 background_tasks 字段。强制 bg=[](空快照)→ translate 差集会把该会话所有后台子项收尾。
            action = .done(reply: Self.string(dict, "last_assistant_message"))
            bg = []
            subDescs = Self.parseSubagentDescriptions(dict, session: session)

        case "SubagentStop":
            // 子任务结束(parentId != nil):由 SubagentStart/SubagentStop 事件精确跟踪,**不**在此做 background_tasks 差集
            // (其数组是父会话范围,会与父的 Stop 重复;且后台 subagent 的完成有 SubagentStop 这个可靠事件,无需靠"消失"判定)。
            // 但**收割** background_tasks 里本子代理自身的 description(实测常规子代理的 SubagentStop 会带)→ 兜底补 prompt。
            action = .done(reply: Self.string(dict, "last_assistant_message"))
            subDescs = Self.parseSubagentDescriptions(dict, session: session)
            // 保活:SubagentStop 不做 background_tasks 差集(见上),但它仍是"父会话还活着"的信号 →
            // 给此刻仍列在 background_tasks 里的后台进程(含其它 subagent / shell)续期,防父长时间无 turn 时被看门狗误放行。
            keepAlive = Self.parseKeepAliveIds(dict, session: session)

        case "StopFailure":
            // turn 因 API 错误结束。error=类型;last_assistant_message 此处为错误原文。
            let kind = Self.string(dict, "error")
            let detail = Self.string(dict, "error_details") ?? Self.string(dict, "last_assistant_message")
            action = .fail(errorKind: kind, errorDetail: detail,
                           reply: Self.string(dict, "last_assistant_message"))

        default:
            action = .ignore
        }

        return ClaudeHookEvent(id: id, parentId: parentId, name: name, cwd: cwd, action: action,
                               backgroundTasks: bg, subagentDescriptions: subDescs, keepAliveIds: keepAlive)
    }

    /// 在纯 [parse] 之上叠加"子任务输入"关联(有状态)。
    /// **必须每事件只调一次**(`routeClaude` 单点调用):有副作用(暂存/领取/清队列),
    /// 重复调用会双推双弹而串位——故关联逻辑放这里,而非在调试日志里被二次调用的 [parse] 内。
    /// 三个触点:
    ///   - 父 `PreToolUse(Agent/Task)`(toolComplete=false):暂存其输入(`detail` 已是 description,空则退化 prompt);
    ///   - `SubagentStart`(`.start(nil)` 且有 parentId):领取暂存输入作为子任务 prompt,UI 输入行直接复用;领不到则降级为无输入;
    ///   - 父 turn 结束(`.done`/`.fail` 且无 parentId,即 Stop/SessionEnd/StopFailure):清掉该会话残留暂存(turn 边界=状态重置)。
    /// 返回**一个或多个**中立动作:绝大多数 hook 是一个;父会话 Stop/SessionEnd 可能展开成
    /// 「父 done + 各后台子项 update/done」多个动作(见 [backgroundActions])。非 JSON → 空数组。
    static func translate(_ data: Data) -> [ClaudeHookEvent] {
        guard let e = parse(data) else { return [] }
        var out: [ClaudeHookEvent]
        switch e.action {
        case let .update(tool, detail, _, _, toolComplete, _, _)
            where (tool == "Agent" || tool == "Task") && !toolComplete:
            if let sid = e.id, let d = detail, !d.isEmpty { correlator.push(session: sid, input: d) }
            out = [e]
        case .start(nil) where e.parentId != nil:
            if let sid = e.parentId, let input = correlator.pop(session: sid) {
                out = [ClaudeHookEvent(id: e.id, parentId: e.parentId, name: e.name, cwd: e.cwd,
                                       action: .start(prompt: input))]
            } else {
                out = [e]
            }
        case .done, .fail:
            // 子任务的 done/fail 带 parentId,不在此清;只有父 turn 结束(parentId==nil)才重置该会话暂存。
            if e.parentId == nil, let sid = e.id { correlator.clear(session: sid) }
            // 父会话 Stop/SessionEnd 携带 background_tasks(非 nil)→ 差集翻成后台子项的 update/done。
            // .fail(StopFailure)无此字段(bg=nil),自然跳过。
            if e.parentId == nil, let sid = e.id, let bg = e.backgroundTasks {
                out = Self.backgroundActions(session: sid, cwd: e.cwd, tasks: bg, parentDone: e)
            } else {
                out = [e]
            }
        default:
            out = [e]
        }
        // 兜底富化:把 background_tasks 里收割到的 subagent description 翻成 enrich 动作(纯展示,不建项/不改状态/不碰休眠)。
        // 覆盖关联器漏接的常规子代理(其 SubagentStop / 父 Stop 的 background_tasks 带 type=="subagent" 的 description)。
        // workflow 子代理不出现在此(其条目是 type=="workflow"),故对 workflow 子代理无副作用。
        if let descs = e.subagentDescriptions {
            for (cid, desc) in descs {
                out.append(ClaudeHookEvent(id: cid, parentId: nil, name: nil, cwd: nil,
                                           action: .enrich(prompt: desc)))
            }
        }
        // 保活:background_tasks 里仍在运行的后台进程(所有 type)= 活着的实证 → 刷新其 lastSeen,
        // 防看门狗在无其它事件时误判"疑似已断"提前放行休眠。纯保活(store.keepAlive 只对已存在的 working 项生效,
        // 不建项/不改状态/不复活终态)。Stop 上 shell 子项已被 backgroundActions 的 update 折叠刷新过,这里再保活是
        // 幂等冗余;真正补上的是 subagent 子项(Stop 此前只 enrich 不刷 lastSeen)与整个 SubagentStop 路径(此前完全不刷)。
        // 冗余无害:keepAlive 仅 refresh 已存在的 working 项。刚 SubagentStop 的子代理自身即便还列在快照里,也因其 done
        // 动作在此之前入队(串行队列先执行)、guard status==working 落空而被跳过 → 绝不复活。
        if let ids = e.keepAliveIds {
            for kid in ids {
                out.append(ClaudeHookEvent(id: kid, parentId: nil, name: nil, cwd: nil, action: .keepAlive))
            }
        }
        return out
    }

    /// 把一次父会话 Stop/SessionEnd 的后台任务快照,翻成中立动作序列:
    ///  - 仍在运行的后台任务 → `update`(working)(幂等 upsert,持续阻止休眠;折叠 id=`session#bg:taskId`,parentId=session);
    ///  - 自上次快照后**消失**的后台任务 → `done`(后台进程退出无任何事件,实测只能靠"上次在、这次不在"判完成)。
    ///
    /// 顺序刻意为「先各后台子项 update(working) → 父 done → 各后台子项 done」:让 working 子项在父 done 之前就位,
    /// 避免父 done 那一刻集合里短暂无 working 项而误放行休眠(IOPMAssertion 抖动)。
    ///
    /// 这些都是普通的 update/done(带 parentId)——中立 `/v1/task/*` 同样能表达,适配器只是把 Claude 的快照翻成它们。
    private static func backgroundActions(session: String, cwd: String?,
                                          tasks: [BgTask], parentDone: ClaudeHookEvent) -> [ClaudeHookEvent] {
        // 只把"仍在运行"的折成 working 子项;明确终态的不折(否则会一直阻止休眠到看门狗超时)。
        // 某任务若上轮在跑、这轮变终态,会因不在 runningIds 而被差集判完成 → done(见下)。
        let running = tasks.filter { !Self.isTerminalBgStatus($0.status) }
        let runningIds = Set(running.map { childId(session: session, taskId: $0.id) })
        let completedIds = bgTracker.reconcile(session: session, running: runningIds)

        var out: [ClaudeHookEvent] = []
        for t in running {
            // 后台子项当前动作:shell 显示命令,否则退化到描述(纯展示;popover 会截断)。
            let detail = (t.command?.isEmpty == false) ? t.command : t.description
            out.append(ClaudeHookEvent(
                id: childId(session: session, taskId: t.id), parentId: session, name: t.type, cwd: cwd,
                action: .update(tool: nil, detail: nil, reply: detail, replyAppend: false, toolComplete: false)))
        }
        out.append(parentDone)
        for cid in completedIds {
            out.append(ClaudeHookEvent(id: cid, parentId: session, name: nil, cwd: nil, action: .done(reply: nil)))
        }
        return out
    }

    /// 后台任务折叠 id:`session#bg:taskId`。前缀 `bg:` 避免与 subagent 子任务 `session#agentId` 撞 id。
    private static func childId(session: String, taskId: String) -> String { "\(session)#bg:\(taskId)" }

    /// 后台任务状态是否"已终结"(不再阻止休眠)。实测只见过 "running",但文档未穷举状态值;
    /// 故保险:仅明确的已知终态字样才算终结,nil / "running" / 未知一律按运行中(守"宁可多醒不可漏醒")。
    private static func isTerminalBgStatus(_ status: String?) -> Bool {
        guard let s = status?.lowercased() else { return false }
        return ["completed", "complete", "done", "finished",
                "failed", "error", "stopped", "canceled", "cancelled", "killed", "exited"].contains(s)
    }

    // MARK: - 接入提示词(onboarding)

    /// 写进 hooks 的全部事件(与上面 parse 的 switch 一一对应)。
    static let hookEvents = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "MessageDisplay", "Notification", "PermissionRequest", "SubagentStart",
        "SubagentStop", "Stop", "StopFailure", "SessionEnd",
    ]

    /// 给 Claude Code 的"一键接入"提示词(端口现取实际值填好)。用户从 popover ⋯「接入 agent…」复制,
    /// 粘进自己的 Claude Code,由它幂等合并进 `~/.claude/settings.json`。BusyElf 全程不碰用户文件。
    /// 用 Claude 原生 `type:"http"` hook(无需 jq/curl);端口已钉死稳定,贴进去后长期有效。
    static func installPrompt(port: UInt16) -> String {
        let url = "http://127.0.0.1:\(port)/claude/hooks"
        let lines = hookEvents.map {
            "    \"\($0)\": [{ \"hooks\": [{ \"type\": \"http\", \"url\": \"\(url)\", \"timeout\": 5 }] }]"
        }.joined(separator: ",\n")
        let hooksJSON = "{\n  \"hooks\": {\n\(lines)\n  }\n}"
        return """
        # Connect BusyElf to Claude Code

        BusyElf is a passive macOS menubar app that blocks system sleep while an agent is \
        working and shows each task's status. It only *observes* Claude Code through hooks — \
        it never changes your prompts, tools, or flow. Configure the hooks below so it can see activity.

        ## Steps
        1. Pick where to install, then open that file (create it containing `{}` if missing):
           - **User-level** `~/.claude/settings.json` — applies to every project. Most convenient; recommended.
           - **Project-level** `<this-project>/.claude/settings.local.json` — only this project, personal & \
        git-ignored (use `<this-project>/.claude/settings.json` instead if you want to commit it for the team). \
        Choose this if you only want BusyElf for the current project. Ask the user which they prefer if unsure.
        2. **Back it up first**: copy it alongside as `<the-file>.busyelf-backup`.
        3. **Merge** the `hooks` block below into that file:
           - If there is no `hooks` key, add it.
           - If `hooks` already exists, merge per event: keep the user's existing entries and add \
        BusyElf's. If a BusyElf entry is already there (an `http` hook whose `url` ends with \
        `/claude/hooks`, possibly on a different port), **replace it in place** — so this is safe to re-run.
           - Never remove or alter the user's other (non-BusyElf) hooks.
        4. Save valid JSON.

        ```json
        \(hooksJSON)
        ```

        ## Verify
        Post a one-off test task — it starts, then completes, so a finished item shows up in BusyElf:
        ```
        curl -sS -m2 -X POST \(url) -d '{"hook_event_name":"UserPromptSubmit","session_id":"busyelf-setup-test","prompt":"🎉 BusyElf connected — open this panel to see how tasks show up."}'
        curl -sS -m2 -X POST \(url) -d '{"hook_event_name":"Stop","session_id":"busyelf-setup-test","last_assistant_message":"Setup looks good. From now on, while an agent is working your Mac will not idle-sleep. This is a one-off test task — it clears itself once you close this panel."}'
        ```
        Then tell the user: click the BusyElf ⚡ in the menubar — they should see a completed test task \
        (green dot) with the message above. Opening the panel marks it read; closing the panel removes it \
        automatically (BusyElf keeps finished tasks only until you've seen them). If the curl cannot connect, \
        BusyElf is not running or is on a different port — ask the user to launch BusyElf and re-open this setup.

        Notes:
        - All events point to the same URL; BusyElf routes internally by event name.
        - BusyElf always replies 2xx with an empty body, so these hooks never block or alter Claude Code.
        """
    }

    // MARK: - 私有

    /// 取字符串字段;数字也强转字符串。缺失/类型不符 → nil。
    private static func string(_ dict: [String: Any], _ key: String) -> String? {
        guard let v = dict[key] else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// 解析 Stop 输入里的 `background_tasks`(v2.1.145+)。
    /// key 不存在 → nil(老版本/注册表不可达,不做差集);存在(含空数组)→ 解析出的列表。
    /// **剔除 type=="subagent"**:后台子代理由 SubagentStart/SubagentStop 事件精确跟踪(其 id==agent_id,
    /// 折叠成 `session#agentId`),与这里的 `session#bg:taskId` 不同;若在此一并折叠会重复建项。
    private static func parseBackgroundTasks(_ dict: [String: Any]) -> [BgTask]? {
        guard let arr = dict["background_tasks"] as? [[String: Any]] else { return nil }
        return arr.compactMap { item -> BgTask? in
            guard let tid = string(item, "id"), !tid.isEmpty else { return nil }
            let type = string(item, "type")
            if type == "subagent" { return nil }
            return BgTask(id: tid, type: type, status: string(item, "status"),
                          command: string(item, "command"), description: string(item, "description"))
        }
    }

    /// 从 background_tasks **只取** `type=="subagent"` 条目的 description,返回 折叠 id(`session#agentId`)→ description。
    /// 与 [parseBackgroundTasks] 互补:那个剔除 subagent(用于折叠/差集),这个专取 subagent 的 description(用于兜底富化)。
    /// 实测:常规 Task/Agent 子代理在自身 `SubagentStop`(及在跑时的父 `Stop`)的 background_tasks 里以 `type:"subagent"`
    /// 出现并带 `description`(= Agent 工具的 description);而 workflow 子代理**不**出现(其条目是父 workflow,`type:"workflow"`,
    /// description 是 workflow 而非子代理),故此收割对 workflow 子代理零副作用——它们的 prompt 确实不在任何 hook 里。
    private static func parseSubagentDescriptions(_ dict: [String: Any], session: String?) -> [String: String]? {
        guard let session, !session.isEmpty,
              let arr = dict["background_tasks"] as? [[String: Any]] else { return nil }
        var map: [String: String] = [:]
        for item in arr where string(item, "type") == "subagent" {
            guard let tid = string(item, "id"), !tid.isEmpty,
                  let desc = string(item, "description"), !desc.isEmpty else { continue }
            map["\(session)#\(tid)"] = desc   // 折叠 id 与 SubagentStart 一致(子代理无 "bg:" 前缀)
        }
        return map.isEmpty ? nil : map
    }

    /// 从 background_tasks 取**所有仍在运行**条目的折叠 id(不分 type),用于保活(刷新 lastSeen)。
    /// 折叠 id 与各自的建项路径严格一致:`type=="subagent"` → `session#agentId`(SubagentStart 那套),
    /// 其余(shell/workflow/…)→ `session#bg:taskId`([childId] 那套)。剔除明确终态(只给活着的续期)。
    /// 缺 background_tasks / 无 session → nil。与 [parseBackgroundTasks]/[parseSubagentDescriptions] 刻意分开:
    /// 保活是"证明还活着"的正交关注点,覆盖所有 type,且绝不建项/改状态(下游 keepAlive 只 refresh 已存在的 working 项)。
    private static func parseKeepAliveIds(_ dict: [String: Any], session: String?) -> [String]? {
        guard let session, !session.isEmpty,
              let arr = dict["background_tasks"] as? [[String: Any]] else { return nil }
        var ids: [String] = []
        for item in arr {
            guard let tid = string(item, "id"), !tid.isEmpty else { continue }
            if isTerminalBgStatus(string(item, "status")) { continue }
            let fold = (string(item, "type") == "subagent") ? "\(session)#\(tid)"
                                                            : childId(session: session, taskId: tid)
            ids.append(fold)
        }
        return ids.isEmpty ? nil : ids
    }

    /// 取整型字段。缺失/类型不符 → nil。
    private static func int(_ dict: [String: Any], _ key: String) -> Int? {
        if let n = dict[key] as? NSNumber { return n.intValue }
        if let s = dict[key] as? String { return Int(s) }
        return nil
    }

    /// 为"阻塞等用户"类工具(AskUserQuestion / ExitPlanMode)凑一句 waiting 提示(纯展示,popover 会截断)。
    /// AskUserQuestion:取第一个问题文本(退化用 header);ExitPlanMode:plan 太长,给固定语义提示。
    private static func blockingToolPrompt(tool: String?, input: [String: Any]?) -> String? {
        if let questions = input?["questions"] as? [[String: Any]], let first = questions.first {
            return string(first, "question") ?? string(first, "header")
        }
        if tool == "ExitPlanMode" { return L.Wait.approvePlan }
        return nil
    }

    /// 从 `tool_input` 里尽力凑一条"当前工作"细节(纯展示)。按各内置工具的参数名优先级取第一个非空。
    private static func toolDetail(_ input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in ["command", "file_path", "path", "pattern", "url", "notebook_path", "description", "prompt"] {
            if let v = string(input, key), !v.isEmpty { return v }
        }
        return nil
    }
}

/// 子任务输入暂存:父 `PreToolUse(Agent)` 入队、紧接的 `SubagentStart` 领取(按 session_id FIFO)。
/// **双重上限防无限增长**:单会话队列上限 + 跟踪会话总数上限(超出淘汰最旧会话);另由 [ClaudeHookEvent.translate]
/// 在父 turn 结束时清队列。线程安全(hook 可能来自不同连接,虽源头串行仍加锁保内存安全)。
/// 关联失败只是子任务无输入行(优雅降级),绝不影响休眠/状态正确性。
private final class SubagentInputCorrelator {
    private let lock = NSLock()
    private var pending: [String: [String]] = [:]   // session_id → 待领取输入队列(FIFO)
    private var order: [String] = []                 // session 插入顺序,用于会话级淘汰
    private let perSessionCap = 8                     // 单会话队列上限(SubagentStart 缺失时不无界堆积)
    private let sessionCap = 32                       // 跟踪会话总数上限(长跑下不无界堆积)

    func push(session: String, input: String) {
        lock.lock(); defer { lock.unlock() }
        if pending[session] == nil { order.append(session) }
        var q = pending[session] ?? []
        q.append(input)
        if q.count > perSessionCap { q.removeFirst(q.count - perSessionCap) }
        pending[session] = q
        while order.count > sessionCap, let oldest = order.first { removeLocked(oldest) }
    }

    func pop(session: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard var q = pending[session], !q.isEmpty else { return nil }
        let v = q.removeFirst()
        if q.isEmpty { removeLocked(session) } else { pending[session] = q }
        return v
    }

    func clear(session: String) {
        lock.lock(); defer { lock.unlock() }
        removeLocked(session)
    }

    /// 需在持锁下调用:移除某会话的全部暂存与顺序记录。
    private func removeLocked(_ session: String) {
        pending[session] = nil
        if let i = order.firstIndex(of: session) { order.remove(at: i) }
    }
}

/// 后台任务差集跟踪:记录每会话上次 Stop 快照里"仍在运行"的后台子项 id 集合。
/// 后台进程(shell 等)结束时 Claude Code **不发任何 hook 事件**(实测),只能靠"上次在、这次不在"判完成。
/// 线程安全(hook 源头串行,仍加锁保内存安全);会话数上限防长跑无界堆积。
/// 差集失准只会让某后台子项晚一点被 done(看门狗兜底放行休眠),绝不影响休眠正确性。
private final class BackgroundTaskTracker {
    private let lock = NSLock()
    private var lastSeen: [String: Set<String>] = [:]   // session → 上次仍在运行的后台子项折叠 id 集
    private var order: [String] = []                    // session 插入顺序,用于会话级淘汰
    private let sessionCap = 64

    /// 用本次快照的运行集刷新该会话,返回"消失了"的子项 id(= 已完成,需置 done)。
    /// running 为空 → 该会话不再有后台任务,清掉其记录(SessionEnd 走此路:drain 全部)。
    func reconcile(session: String, running: Set<String>) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let prev = lastSeen[session] ?? []
        let completed = prev.subtracting(running)
        if running.isEmpty {
            removeLocked(session)
        } else {
            if lastSeen[session] == nil { order.append(session) }
            lastSeen[session] = running
            while order.count > sessionCap, let oldest = order.first, oldest != session { removeLocked(oldest) }
        }
        return completed
    }

    /// 需在持锁下调用。
    private func removeLocked(_ session: String) {
        lastSeen[session] = nil
        if let i = order.firstIndex(of: session) { order.remove(at: i) }
    }
}
