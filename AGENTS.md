# AGENTS.md — 给 AI agent 的工作指南

BusyElf 是一个**极致轻量的原生 macOS 菜单栏常驻 app**:有 AI agent(Claude Code / Codex 等)在跑长任务时**阻止系统休眠**,任务结束后恢复;菜单栏图标实时显示在干活/等待/完成/失败,popover 列出每个任务。它通过一套 **agent 无关的本地 HTTP 协议**接收事件,本身不绑定任何工具。

读这份就够上手。深入细节见 `docs/`(末尾有索引)。

---

## ⚠️ 硬约束(改动前必读,违反即破坏产品定位)

1. **纯 AppKit,永不链接 SwiftUI**。这是 12MB footprint 的关键(若 popover 用 SwiftUI,phys_footprint 飙到 ~129MB)。UI 全部手写 AppKit,见 `Sources/BusyElf/UI/`。不要 `import SwiftUI`、不要用 `@State`/`some View`。
2. **休眠正确性 > 一切**。阻止休眠 ⟺ 存在任一 `working` 任务**且其未"疑似已断"**(`now − lastSeen ≤ 无活动阈值`,默认 15min,看门狗;见下)。
   - 用**集合成员**(`[id: TaskSession]` 字典)判断,**绝不用 `+1/-1` 整数计数**——事件 at-least-once 且可能丢失/乱序,整数会漂移成负数或卡正 → **永久阻止休眠**(本 app 绝不能有的 bug)。看门狗只是把判据从 `status==.working` 收紧为 `.working && !isStalled`(`TaskStore.hasBlockingWorking`),仍是集合成员判定,不引入计数。
   - **body 解析失败绝不能影响休眠逻辑**。休眠只看 路径(动词)+ `id`;其它字段解析不到只做展示降级。
   - 宁可多醒不可漏醒:漏 `start` 也能靠 `update`/`wait`/`fail` 的 upsert 接管(中途启动)。丢了 `done`/`fail` 也由看门狗在无活动超时后放行休眠(可逆:任一动词刷新 `lastSeen` 即恢复阻止)。
3. **agent 中立核心**。`TaskStore` / 协议核心**永不 import 任何特定 agent 的概念**。所有"懂 Claude 字段名/事件语义"的代码**只允许**待在 `Server/ClaudeHookEvent.swift` 一个文件里。新增其它 agent 适配也照此隔离。
4. **`/claude/hooks` 永远回 `2xx + 空 body`**。BusyElf 是纯被动观察者:绝不向 agent 注入上下文、不阻止工具、不改流程。
5. **菜单栏图标绝不替换字形**(`bolt.fill` 固定)。换字形会改宽度让菜单栏抖动。状态靠 着色 / 数字 / 透明度 / 右上角合成角标 传达。见 `UI/StatusItemController.swift`。
6. **idle 0 CPU**。服务端事件驱动(`NWListener`,kqueue 阻塞);popover 的 1s ticker 仅在可见时运行。别引入轮询/常驻定时器。**看门狗例外但守此约束**:它的一次性 `DispatchSourceTimer` 只在有 `working` 任务时存在、精确调度到截止点,无 working 即取消——此时机器本就因阻止休眠而醒着,不是常驻轮询。
7. **popover 紧凑**:每个 item 文本 ≤2-3 行、尾部 `...` 截断(`UI.label(truncates:)`)。不追求展示完整,有问题让用户回 agent 那边看。

---

## 架构与数据流

```
agent 原生事件(hook / lifecycle)
   │ 翻译在适配器层
   ▼
LoopbackServer (127.0.0.1, NWListener, 手写 HTTP)   Server/LoopbackServer.swift
   │ Router 按路径分流                               Server/Router.swift
   ├─ /claude/hooks  → ClaudeHookEvent 翻译(唯一懂 Claude 的文件)  Server/ClaudeHookEvent.swift
   └─ /v1/task/*     → TaskEvent 中立 body 解析                      Server/TaskEvent.swift
   ▼ 六个中立动词
TaskStore  [id: TaskSession]  串行队列, 幂等 upsert/标记         State/TaskStore.swift
   │ reconcile()                                                 State/TaskSession.swift(值类型)
   ├─▶ SleepGuard      存在 working → 持 IOPMAssertion 阻止休眠   Power/SleepGuard.swift
   └─▶ 主线程回调 onChange / onAttention / onTerminalAlert
        └─▶ AppDelegate → StatusItemController(图标)+ PopoverController(列表)  UI/, App/AppDelegate.swift
```

- 真相源是 `TaskStore.sessions` 字典,**单串行队列** `elf.busyelf.taskstore` 保护。所有动词走 `queue.async { … reconcile() }`。
- `reconcile()` 四件事:`SleepGuard.setBlocked(hasBlockingWorking)`、安排看门狗截止点(`scheduleWatchdogLocked`)、主线程派发排序快照、`→waiting`/`→failed` 跳变发系统横幅(去抖)。
- 运行期配置在 `Config/AppConfig.swift`(端口/网口/看门狗阈值);`AppDelegate` 启动时把阈值注入 `TaskStore.setInactivityTimeout`。
- UI 只读快照重绘(`PopoverController.rebuild()` 按 id 复用行对象)。

---

## 协议(六动词)与状态机

中立端点 `POST /v1/task/{start,update,wait,done,fail,remove}`;除 `id` 外字段全可选、容错降级。

| 动词 | 效果 |
|---|---|
| `start`  | upsert→working;记 prompt / 子任务标签(name)/ parentId;新 turn 清旧回复 |
| `update` | upsert→working,**复活终态/waiting**;刷新当前动作(tool 优先,退化 reply)与回复(`reply`+`replyAppend` replace/append) |
| `wait`   | upsert→waiting(总是创建);放行休眠 + 点亮"需要关注" |
| `done`   | 已存在→done(终态,不删;**顶层**留绿点提示,子任务完成静默);failed 不被覆盖 |
| `fail`   | upsert→failed(失败优先;红点);记 errorKind/errorDetail |
| `remove` | 真正移除(级联子任务) |

`status ∈ {working, waiting, done, failed}`。`working` 阻止休眠;`waiting/done/failed` 放行。终态留存展示,靠 **seen 生命周期**清理:打开 popover→`markTerminalSeen`(清角标),关闭→`purgeSeenTerminal`(下次打开消失);另有 TTL/数量上限兜底(`pruneLocked`)。

**菜单栏完成提示(绿点/绿闪电)只由顶层任务点亮**:`hasUnseenDone` 计算时排除子任务(`!isSubtask`,见 `AppDelegate.refreshStatus` 与 `debugStateJSON`,两处判据须一致)——子任务(subagent/后台子项)完成**静默**,不通知、不亮绿点(它们是父任务内部步骤、数量多)。与失败"整只闪电烤红"统一 UX:未看顶层 done **且无任何活动任务时**整只闪电烤绿 + 右上角绿点;仍在 working/waiting 时只保留绿点、底图随忙碌态(避免"看着像全好了"误导休眠)。失败红优先级最高、任何时候整只烤红。见 `UI/StatusItemController.swift`。**已完成子任务列表封顶**(`maxDoneSubtaskCount=20`,`pruneLocked`):done 子任务超上限按 `endedAt` 删最旧,防多子代理的父完成后堆积;failed 子任务不在此静默删。

**看门狗(派生 stalled,不加第 5 个状态)**:`working` 任务 `now − lastSeen > inactivityTimeout`(默认 15min,可配)→ 派生为"疑似已断",`hasBlockingWorking` 把它排除 → **放行休眠**。状态仍是 `working`(不谎报 done/failed、不弹横幅),UI 标灰 + "可能已断";任一动词刷新 `lastSeen` 即自动恢复阻塞。靠 `reconcile` 里一次性 timer 精确到截止点重算;超久(默认 6h)仍无活动则在 `pruneLocked` 兜底移除。

**子任务(subagent)**:把子 id 折进 `id`(`"父id#子id"`)+ `parentId` 表达;有 `parentId` 即子任务。折叠只发生在适配器边界,核心层无感。

**子任务的"它在干什么"展示(三档来源,逐级退化)**:子代理的 prompt/description 决定 UI 锚点行(识别任务的那行)。① **关联器**(`SubagentInputCorrelator`):父 `PreToolUse(Agent/Task)` 的 `description`(空则退化 `prompt`)按 session 暂存,紧接的 `SubagentStart` 领取——这是常规 Task/Agent 子代理的主来源。② **background_tasks 收割兜底**(`enrich` 动作):`SubagentStop`(及在跑时的父 `Stop`)的 `background_tasks` 里 `type:"subagent"` 条目带 `description`,据此 `enrichPrompt`(仅当 prompt 空才补,不建项/不改状态/不碰休眠),兜底关联器漏接的常规子代理。③ **锚点退化到 activity**(`AgentRowView.anchorText`):**workflow 子代理**(`agent_type:"workflow-subagent"`)的 prompt/label/description **不在任何 hook 里**(实测确证:`SubagentStart` 不带;其 `SubagentStop.background_tasks` 给的是父 workflow `type:"workflow"` 而非子代理自身;真 prompt 只在子代理 transcript 文件,纯被动观察者不读)——故 ①② 都拿不到,UI 在**非 working 态**把 `activity`(它做过的活,如 `Bash: …`)退化进锚点行,让 done/failed 态不至于只剩通用标题 "workflow-subagent" + 一句 reply。working 态不退化(activity 已在主信息行实时显示)。

**后台任务(background_tasks,turn 结束但活儿没完)**:agent 用 `run_in_background` 起的 shell 等后台进程会让父 turn 结束(`Stop`)、进程却仍在跑。后台进程**结束时 Claude Code 不发任何 hook**(实测),唯一信号是 `Stop`/`SessionEnd` 输入里的 `background_tasks[]`(v2.1.145+,每条 `id/type/status/command`)。适配器在 `Stop` 把每条仍 `running` 的后台任务折成后台子项(`"父id#bg:taskId"`,`parentId`=父,working → 持续阻止休眠),父照常 `done`;**完成靠差集**——某后台任务"上个 Stop 在、这个 Stop 没了"即判完成→子项 `done`(`SessionEnd` 视为空快照→收尾全部)。`task.id` 跨 turn 稳定(实测=后台句柄)。**`type:"subagent"` 跳过**:后台子代理由 `SubagentStart`/`SubagentStop` 事件精确跟踪(`id`=`agent_id`,折成 `父id#agent_id`),在此一并折会重复建项。一个 `Stop` 因此可能翻成**多个**中立动作(父 done + 各后台子项 update/done),故 `translate` 返回数组、`Router.routeClaude` 遍历分发。这些都是普通 update/done(带 parentId),中立 `/v1/task/*` 同样能表达,parity 不破。

**后台子项保活(keepAlive,防看门狗误放行):**后台子项 `working` 阻止休眠,但看门狗只看 `lastSeen`——后台进程在跑却无 hook 时,`lastSeen` 会陈旧,超 15min 就被判"疑似已断"放行休眠。修法:适配器在 `Stop`/`SubagentStop` 见某后台条目**仍列在 `background_tasks` 里(=活着的实证)**→ 对其折叠 id 发 `keepAlive`(`TaskStore.keepAlive` 只刷新已存在的 `working` 项的 `lastSeen`,**不建项/不改 status/不复活终态**——这条 `status==.working` guard 是安全核心,顶住 at-least-once 陈旧快照)。折叠 id 与建项路径一致(subagent→`父id#agentId`,其余→`父id#bg:taskId`),覆盖 `Stop` 上此前只被 `enrich` 不刷 `lastSeen` 的 subagent 子项、以及整个 `SubagentStop` 路径(此前完全不刷)。`SessionEnd` 除外(收尾 drain,不续期)。这不是新动词:中立客户端知道任务活着时直接发 `update`(同样刷 `lastSeen`)即可,parity 不破;`keepAlive` 只是适配器**不能**用 `update`(其 upsert+复活会从陈旧快照凭空建项/复活已完成子代理)时的收敛原语。

**父任务保留(有在跑子任务不清父)**:父已终态但**仍有非终态子任务**(后台子项 / subagent 在跑)时,清理逻辑(`purgeSeenTerminal` / `pruneLocked` 的 TTL & 数量上限)**跳过该父**(`parentsWithLiveChildrenLocked`),否则在跑的子任务变孤儿、UI 错乱;子全终结后父子一起清。子任务休眠由 `hasBlockingWorking`(含子)+ 看门狗 `isStalled` 兜底;孤儿降级只在"父**已不在**"(非"父终态")时触发,以免把仍在跑的后台子项误判完成而提前放行休眠。

**Claude 适配映射**(`ClaudeHookEvent.swift`):`UserPromptSubmit`→start、`SubagentStart`→start(子)、`PreToolUse`/`PostToolUse`→update(✓)、`PostToolUseFailure`→update(✗,工具失败是常态非中断,仍 working)、`MessageDisplay`→update(reply)、`Notification`(读 `notification_type`:permission→wait / idle→忽略)、`Stop`→done **+ `background_tasks` 差集折成后台子项 update/done + 在跑条目 keepAlive**、`SubagentStop`→done(子)**+ 在跑条目 keepAlive**、`SessionEnd`→done **+ 收尾后台子项**(不 keepAlive)、`StopFailure`→fail。subagent 靠 `agent_id`/`agent_type`,**session_id 与父相同**;后台任务靠 `background_tasks`(折叠/差集时剔除 subagent,keepAlive 不分 type)。

---

## 构建 / 运行 / 测试(全 CLI,永不打开 Xcode)

`project.yml`(XcodeGen)是工程**唯一真相源**;`.xcodeproj` 由它生成、**gitignore、从不手改**。

```bash
# 一键拉起(最常用):构建(若需要)→ 关掉本仓库旧实例 → 后台启动,菜单栏出现 ⚡
scripts/run.sh
#   --build 强制重建 / --debug 带 BUSYELF_DEBUG=1(开 /debug/*,日志 /tmp/busyelf.log)/ --stop 仅停

# 或手动构建 + 运行(run.sh 内部就是这套)
xcodegen generate
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/BusyElf.app
pmset -g assertions | grep BusyElf      # 有 working 任务时见 PreventUserIdleSystemSleep

# 测试(两层,各一行)
scripts/test-unit.sh        # 白盒单元(XCTest):状态机 / 适配器映射 / 解析
scripts/test-busyelf.sh     # 端到端:自启实例 → 打真实端点 → 断言内部状态(覆盖 7 大需求)
```

- 目标 **0 warning**。改完务必跑这两个脚本,都绿才算完成。
- **观测/测试接口** `/debug/*` **默认关闭**,仅以 `BUSYELF_DEBUG=1` 启动时开启(生产不暴露内部状态):
  - `GET /debug/state` → 内部状态 JSON + 派生量(`blocking`/`hasUnseenDone`/`hasUnseenFailed`)。读用 `queue.sync`,兼作**写后读屏障**,断言无需 sleep。
  - `POST /debug/{reset,seen,purge}` → 清空 / 模拟打开 popover / 模拟关闭。
- 单元测试在 `Tests/`(target `BusyElfTests`,宿主测试;`AppDelegate` 在 XCTest 下跳过装配)。`TaskStore` 的同步测试辅助(`snapshotSync`/`resetSync`)用 `#if DEBUG` 包裹,**不进 Release**。

---

## 扩展点(怎么加东西)

- **加一个新的中立字段**:`TaskSession`(展示状态)+ `TaskEvent`(中立 body 解析,可选 + 容错)同步加;`Router` 透传;按需在 `ClaudeHookEvent` 填充。中立接口要与 `/claude/hooks` **表现力对等**(子任务/流式回复/失败细节都用通用语义字段,不漏 Claude 概念)。
- **加一个 Claude hook 事件**:只改 `ClaudeHookEvent.parse` 的 switch + 在 `docs/SETUP.md` 的推荐配置里加该事件指向 `/claude/hooks`。核心层不动。
- **加一个新动词**:`Router.TaskVerb` + `verb(for:)` + `route` + `TaskStore` 加方法(照 `queue.async{…reconcile()}` 骨架)+ `docs/PROTOCOL.md`。
- **加一个配置项**:`Config/AppConfig.swift` 加纯静态 `resolveXxx`(env > UserDefaults > 默认)+ 属性;布尔类宜走右键菜单复选(`AppDelegate.showContextMenu`),数值类走 `defaults write elf.busyelf <key>`。env 层(`BUSYELF_*`)供测试覆盖,别污染用户 defaults。
- **改 UI**:复用 `UI.label/DotView/HoverRow/ClickableRow`(`UI/AppKitHelpers.swift`)、`Format.duration/ago`。

每加一处行为,**在两个测试脚本里补断言**(E2E 断 `/debug/state`,单元断内部逻辑)。

---

## 调试技巧:捕获 Claude Code 真实 hook 事件(比读日志强,免重建 BusyElf)

要搞清"某场景下 Claude Code 到底发了哪些 hook、字段长啥样"(如 `Stop.background_tasks` 的真实形态、新字段、id 是否跨 turn 稳定),**别凭文档/记忆猜,也别给 BusyElf 加日志重新构建**。最快的是临时旁挂一个捕获服务,把原始 hook body 全量落盘:

1. **起本地捕获服务** `scripts/capture-hooks.py`(已固化备用):每个 POST 的 body 带时间戳追加进 JSONL,**立即回 `200` 空体**(行为同 BusyElf,绝不干扰 Claude 流程)。用 `nohup python3 scripts/capture-hooks.py &` 独立起(不占 Claude 后台任务槽,这样 `background_tasks` 里只剩你要观测的目标);默认端口 `17899`、日志 `$TMPDIR/busyelf-hook-capture.jsonl`(端口/日志可经 argv 或 `BUSYELF_CAPTURE_PORT`/`BUSYELF_CAPTURE_LOG` 覆盖;`--logpath` 打印日志路径供 `cat`/`jq`)。
2. **临时加一条 capture hook**:`cp` 备份当前会话的 `settings.json`(项目级 `.claude/settings.local.json` 最稳、个人、gitignored),然后给关心的事件**追加第二条** `{"type":"http","url":"http://127.0.0.1:<capport>/…"}`——**只加,绝不动 BusyElf 那条**。Claude Code 会跑完所有 hook,于是你拿到一份副本。settings.json **改动会被热加载**(文件监视器),当前会话即生效,无需重启 Claude Code。
3. **触发场景并读取**:正常干活触发事件;`Stop` 在你**结束本轮**那一刻才发,所以要跨 turn 读取。多轮编排不靠外部定时器——**每个 `run_in_background` 进程/子代理完成都会独立把 agent 唤醒起新 turn**(即便另有后台进程仍在跑),拿它当"节拍器":起个短 `sleep` 后台进程,结束本轮 → 它完成时把你唤回读捕获。
4. **务必清理**:`cp` 备份覆盖回 `settings.json`(逐字节还原,`diff` 验证)、`pkill` 捕获服务、`kill` 测试用后台 sleep。改的是用户 Claude Code 配置,收尾要干净。

`background_tasks`、`task.id` 跨 turn 稳定、五处 id 同源等结论都是这么实测出来的(对应记忆 `busyelf-bg-process-sleep`)。这套方法对"加新 hook 适配/核对字段名"都通用。

---

## 调试教训(踩过的坑)

- **反复推理框架行为失败时,立刻插桩测量,别接着猜。** popover "撑大缩不回" 曾改了 4 轮(fittingSize 时机 / 表头 hugging / compression resistance)都没消失——全是基于"看似合理"的推理。真凶(`view.fittingSize` 含 `NSScrollView` + 隐藏 `emptyView` 时**恒返回错值**)是加一行 `NSLog` 打出 `listFrameH/constraint/fittingH` 后**一眼看出**的。**对 AutoLayout / fittingSize / NSStackView 这类行为别凭脑补下"根因"结论;打日志看真实数值。**
- **含 `NSScrollView` 的层级,别用 `view.fittingSize` 求 popover 高度。** 滚动视图设计上就"内容任意大、自己滚动",不会把内容高报成自身尺寸。要"列表跟内容长但封顶 320 then 滚动",必须**自己量** `listStack`(普通 stack)的真实高度、取 `min(,320)` 写进 scrollView 的**显式高度约束**,再**逐项求和**(header/footer/分隔线各自 intrinsic + 内容区)算出 `preferredContentSize`。见 `PopoverController.syncContentSize`。
- **行高会变的 UI 别切换到"另一处的更高视图"**(易被裁)。就地原地变换(如 × 原地换成确认按钮),高度不变最稳。
- **XcodeGen 没有 `resources:` target 键——写了被静默忽略。** 资源(如 `AppIcon.icns`)必须挂在 `sources` 下,XcodeGen 按扩展名自动分流到 Resources 构建阶段。曾因这个空操作让图标打不进 .app(`Contents/Resources` 为空、pbxproj 0 引用),改成 `sources: - path: Resources` 才修复。验证:`grep AppIcon.icns *.xcodeproj/project.pbxproj` + 看包内 `Contents/Resources/`。

## 约定

- 注释用**中文**,与现有风格一致;命名/缩进/惯用法贴合周边代码。
- **发布**走免开发者账号的 ad-hoc 路线(`scripts/ci-package.sh` + `.github/workflows/release.yml`):矩阵 `arm64+x86_64`、各出 zip/dmg、单 release job 汇总(`docs/BUILD.md`)。`ci-package.sh` 本地可复现一条腿。用户需一次性放行 Gatekeeper(右键打开在 Sequoia/Tahoe 已失效)。升级到 Developer ID 签名+公证见 BUILD.md。图标:源 `design/AppIcon.svg` → `scripts/make-icon.sh` → `Resources/AppIcon.icns`(`CFBundleIconFile` 引用)。
- **端口黏住(sticky)**:首启探测(首选 `17872` → 候选 `17873/74/75` → 实在没有就 `port 0` 让系统分配),**绑成功后把实际端口持久化钉死**(`AppConfig.persistBoundPort`/`isPortPinned`,键 `portPinned`);此后每次只绑这个端口、**冲突即报错不漂移**(`LoopbackServer.failHard` → `onReachabilityChange(false)` → 菜单栏红角标半透明 + popover 顶部横幅 [重试]/[改端口])。`.ready` 必须从 `listener.port` 取真实端口(`port 0` 退化时尤甚)。这样适配器里写死的端口长期稳定有效。`defaults write elf.busyelf httpPort N` 或面板改端口=重新钉死(需重新复制接入指令)。**调试模式(`BUSYELF_DEBUG=1`)与 env 覆盖(`BUSYELF_HTTP_PORT`)都不持久化、且 debug 忽略已钉死端口**——测试与用户真实 defaults 互不污染。
- **onboarding(接入提示词)**:popover ⋯ →「接入 agent…」弹 `NSAlert`,每条配方一行(标签 + 复制按钮),`AppDelegate` 注入 `setupRecipesProvider`。`ClaudeHookEvent.installPrompt(port:)` 出 Claude 专属版(原生 `type:"http"` hooks,端口现取);`GenericSetupPrompt.installPrompt(port:)` 出中立 `/v1/task/*` 版(无 Claude 字样)。BusyElf 不碰用户文件,由用户自己的 agent 幂等合并进 `settings.json`。加新 harness=数组里加一条配方。
- 默认仅 loopback;右键菜单可切「监听所有网口 (0.0.0.0)」(`AppConfig.listenOnAllInterfaces` + `server.restart()`),无鉴权,仅可信网络用。
- 仅 loopback 可达、**无鉴权**(纯本机同用户场景,刻意从简)。
- 提交信息/PR 按用户要求再做;默认分支上动手前先开分支。

---

## 文档索引(`docs/`)

| 文件 | 内容 |
|---|---|
| `docs/DESIGN.md` | 架构总览、状态机、阻止休眠机制、资源策略、关键决策表 |
| `docs/PROTOCOL.md` | 中立六动词协议(适配器照此对接)+ 内建 `/claude/hooks` |
| `docs/adapters/claude-code.md` | Claude Code 适配:方式 A(HTTP hook,零依赖)/ B(jq+curl);字段映射 |
| `docs/SETUP.md` | 2 分钟把 Claude Code 接进来(推荐 hooks 配置) |
| `docs/UX.md` | 菜单栏 / popover / 提醒 / 强制结束的 UI 设计 |
| `docs/BUILD.md` | 纯 CLI 构建 + **发布**(免账号 ad-hoc 双架构 zip/dmg;升级:签名+公证)+ 图标 + **测试** |
| `docs/claude-code-hooks.md` | Claude Code hooks 官方参考(权威字段来源) |
