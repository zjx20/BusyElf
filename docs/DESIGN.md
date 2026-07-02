# BusyElf 设计总览

> 配套文档:[PROTOCOL.md](PROTOCOL.md)(中立协议)、[UX.md](UX.md)(界面)、[adapters/claude-code.md](adapters/claude-code.md)(Claude Code 适配器)。

## 1. 背景与目标

跑很久的 AI agent loop 经常被系统 idle 休眠打断;手动禁用休眠又会让电脑做完事也不睡。BusyElf 解决这个痛点:

- 常驻菜单栏(`NSStatusItem`),图标显示正在工作的 agent 数量与状态。
- 维护一个"正在工作的任务"集合;**集合非空 → 阻止系统 idle 休眠;集合空 → 恢复休眠。**
- agent 需要用户处理交互(如权限请求)时**提醒用户**,且此时**放行休眠**(等人不算干活)。
- agent 卡死/崩溃没发结束事件时,可在 UI 里**手动移除**该任务以解除休眠阻止。
- **硬性要求:极致省资源**——启动后约十几 MB 内存、空闲时近乎 0 CPU。
- **agent 中立**:不为 Claude Code 定制,而是一套通用协议,未来可接 Codex CLI 等。

## 2. 架构总览

```
   各 Agent(Claude Code / Codex / …)
        │  原生事件(hook/lifecycle)
        ▼
   适配器:两条入口都映射到同一套中立 6 动词
     A) Claude HTTP hook ── 原始 payload ──▶ POST /claude/hooks (BusyElf 内建翻译, 免 jq)
     B) 通用 jq+curl 翻译 ── 中立 body ────▶ POST /v1/task/{start|update|wait|done|fail|remove}
        ▼
   ┌──────────────── BusyElf.app (单进程, 纯 AppKit, LSUIElement) ─────────────┐
   │  LoopbackServer (NWListener, 127.0.0.1, 事件驱动)                          │
   │        │ Router 按路径分流:/claude/hooks → ClaudeHookEvent 翻译;          │
   │        │ /v1/task/* → 中立 body。两者都落到同一套 6 动词 + 容错解析        │
   │        ▼                                                                  │
   │  TaskStore  [id: TaskSession]  串行队列, 幂等 upsert/remove                │
   │        │ reconcile()                                                      │
   │        ├──▶ SleepGuard   (存在 working 任务 → 持有 1 个 IOPMAssertion)     │
   │        ├──▶ StatusItem   (图标: 数量 / working / 需要关注)                 │
   │        ├──▶ Popover      (纯 AppKit, 仅首次打开时懒加载)                   │
   │        └──▶ Notifier     (working→waiting 时发系统横幅)                    │
   └──────────────────────────────────────────────────────────────────────────┘
```

**关键取舍:全程纯 AppKit,完全不链接 SwiftUI。** 因为需要在图标旁画数字徽标、区分左键 popover / 右键菜单、程序化开关 popover——这些 `MenuBarExtra` 都做不到。**popover 内容也用纯 AppKit(`NSViewController` + `NSStackView`/`NSView`)而非 `NSHostingController`**:真机实测发现,只要二进制链接 SwiftUI.framework,dyld 启动即加载并初始化,phys_footprint 就被抬到 ~129MB(落在 SwiftUI 的 30–56MB+ 区间);去掉 SwiftUI 链接后降到 ~12MB。这是"数 MB"硬需求的决定性因素。

- 最低系统:**macOS 14.0**(更好的 SF Symbols 渲染、现代 `SMAppService`)。
- 分发:**Developer-ID 签名 + 公证,App Store 外分发**(推荐;由于不杀进程,沙盒与否不再被强约束,Developer-ID 最省事)。
- **不捆绑任何 helper 二进制**:适配器用用户自带的 `jq` + `curl` 在 hook 里完成,BusyElf 只是个被动的 HTTP 服务端。
- 内存实测:idle **phys_footprint ≈ 12MB**(Activity Monitor "内存"口径),达成"数 MB"硬需求。注意 `ps` 的 RSS(~45MB)把全系统共享框架净页也算进来,虚高且不代表本进程真实占用,衡量内存请以 phys_footprint 为准。

## 3. 核心机制:阻止休眠(SleepGuard)

直接调 **IOKit 电源断言 API**,而非外挂 `caffeinate`。

- `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep, …)` —— 语义等同 `caffeinate -i`:**阻止系统 idle 休眠,但允许显示器自行休眠**(正是所需)。
- 这**不是改 App 内的标志位,而是向系统电源守护进程 powerd 登记一个断言对象**。powerd **聚合全系统所有进程**的断言,只有在没有任何此类断言时才 idle 休眠(`pmset -g assertions` 可查看全部)。可理解为系统维护着一个"保持清醒的理由"集合,集合空了才睡。
- **崩溃安全**:断言绑定进程,**BusyElf 自身一旦退出/崩溃,powerd 自动回收其断言**,绝不会把 Mac 永久钉醒。
- BusyElf 只持有**一个**断言:本地引用计数在 0→1(出现首个 working 任务)时 `create`,1→0(最后一个 working 任务消失)时 `IOPMAssertionRelease`,避免向 powerd 登记 N 条。

```swift
import IOKit.pwr_mgt

final class SleepGuard {
    static let shared = SleepGuard()
    private let lock = NSLock()
    private var count = 0
    private var id: IOPMAssertionID = 0           // uint32; 0 == 未持有

    /// 由 TaskStore 在 0↔1 跳变时驱动
    func setBlocked(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on, id == 0 {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),     // 255
                "BusyElf: agents working" as CFString, &id)
        } else if !on, id != 0 {
            IOPMAssertionRelease(id); id = 0
        }
    }
}
```

**作用边界(UI 文案必须诚实交代)**:`PreventUserIdleSystemSleep` 只阻止**用户空闲导致的系统休眠**。它**管不了**:合盖(clamshell)休眠、Apple 菜单手动休眠、低电量休眠。合盖跑长任务需外接显示器 + 电源。

可选增强:"保持屏幕唤醒"开关 → 额外持有一个 `kIOPMAssertionTypePreventUserIdleDisplaySleep` 断言。

## 4. 中立协议(摘要)

BusyElf 只认识"任务",不认识任何具体 agent。详见 [PROTOCOL.md](PROTOCOL.md)。六个动词:

| Endpoint | 含义 | 主要字段 | 状态效果 |
|---|---|---|---|
| `POST /v1/task/start`  | 开始任务 | `id`*、`prompt?`、`name?`、`parentId?`、`agent?` | → **working** |
| `POST /v1/task/update` | 任务更新 | `id`*、`tool?`、`toolInput?`、`reply?`、`replyAppend?`、`parentId?` | → **working**(终态/waiting 时复活接管) |
| `POST /v1/task/wait`   | 等待用户输入 | `id`*、`message?` | → **waiting** |
| `POST /v1/task/done`   | 任务完成 | `id`*、`reply?` | → **done**(留存提示,不阻止休眠) |
| `POST /v1/task/fail`   | 任务失败 | `id`*、`errorKind?`、`errorDetail?` | → **failed**(红色提示) |
| `POST /v1/task/remove` | 移除任务 | `id`* | 移除任务(级联子任务) |

子任务把子 id 折进 `id`(`父#子`)+ `parentId` 表达。所有 agent 专属知识(字段名、事件语义)都下沉到适配器层;BusyElf 服务端永不 import 一个具体 agent 的概念。中立接口与 `/claude/hooks` 表现力对等。

**内建 Claude 便捷端点**:除中立的 `/v1/task/*`,服务端还内建 `POST /claude/hooks`,直吃 Claude Code 的 HTTP hook 原始 payload(`type:"http"`,免 `jq`+`curl`),按 `hook_event_name` 翻成同一套六动词。Claude 专属知识仍只隔离在 `Server/ClaudeHookEvent.swift` 一个文件里——`TaskStore`/状态机不变,核心仍中立。它让 Claude Code 成为"一等公民",但不耦合:其它 agent 仍走 `/v1/task/*`。该端点始终回 `2xx + 空 body`(Claude 视为无操作),保证 BusyElf 是纯被动观察者。详见 [PROTOCOL.md](PROTOCOL.md) 与 [adapters/claude-code.md](adapters/claude-code.md)。

## 5. 任务状态机

每个任务的状态:`status ∈ { working, waiting, done, failed }`(后两者为终态),加若干展示字段。

派生量:
- **阻止休眠** = 存在任一 `working` 任务(终态不阻止)**且未"疑似已断"**(`now − lastSeen ≤ 无活动阈值`,默认 15min 可配;见 §6 看门狗)。
- **需要关注**(橙) = 存在任一 `waiting` 任务。
- **完成提示**(无 working 时整只烤绿)= 存在任一未看过的**顶层** `done`(子任务完成静默,不染绿);**失败提示**(整只烤红,优先压过一切)= 存在任一 `failed`(含子任务,看过后仍红直到清理/移除)。菜单栏只用整只闪电着色表达,不叠加右上角小圆点(决策见 `StatusItemController.decideVisual`)。

动词 → 状态转移(活动态 working/waiting;终态 done/failed 留存展示,可被 update/start 复活):

| 动词 | 规则 | 理由 |
|---|---|---|
| `start`  | **upsert** → working;复活终态;清旧回复(新 turn) | 任务开始 |
| `update` | **upsert** → working;复活 waiting/终态 | 既是"在干活"心跳,也是恢复信号。**upsert**:漏掉 start 也能接上(中途启动),**宁可多醒不可漏醒** |
| `wait`   | **upsert** → waiting | 需用户处理。中立总是创建("见到请求就追踪") |
| `done`   | 已存在 → done(failed 不被覆盖) | 正常完成,留存提示而非消失 |
| `fail`   | **upsert** → failed(失败优先) | 异常停止,红色紧急提示 |
| `remove` | 移除(幂等,级联子任务) | 用户主动清理 |

> 终态(done/failed)留在字典里供展示,**不阻止休眠**,靠 seen 生命周期清理:popover 打开标 seen(完成绿回落,失败红继续保持)、关闭后 purge(下次打开消失,失败红随之消失),并有 TTL/数量上限兜底。
> 对 Claude Code 的体现:`Stop`→done(完成提示)、`StopFailure`→fail(失败提示)、`SubagentStart/Stop`→子任务。permission vs idle 通知靠**读 `notification_type`** 区分(见下)。阻塞等用户的 `AskUserQuestion`/`ExitPlanMode` 不发 Notification,适配器在其 `PreToolUse` 阶段翻成 `wait`(否则任务会卡 working 误挡休眠)。**权限弹窗**(等用户批准工具)的真实信号是 `PermissionRequest`(IDE/交互模式实测,非 `Notification`),也翻成 `wait`。

幂等设计的原因:事件投递是 at-least-once 且可能丢失。用集合成员而非 `+1/-1` 整数计数器——整数会漂移成负数或卡在正数从而**永久阻止休眠**,这是本应用绝不能有的 bug。

## 6. 崩溃处理、看门狗与强制结束

**不做基于探测的"存活检查"**:不取 PID、不看 transcript mtime、不跑常驻 sweep 轮询。BusyElf 信任适配器/hook 的事件。

- 正常结束:`end`(包括 agent 优雅退出)→ 任务移除,计数准确。
- 硬崩溃 / 链路丢事件(agent 被 SIGKILL、掉电,或某环节有 bug 没发 `done`/`fail`):该任务卡在 `working` → 若不处理会**永久阻止休眠**。

**看门狗(无活动超时 → 放行休眠)**:这是唯一能让任务自动停止阻止休眠的机制,但它**不是存活探测**——只看"距上次有进展(`lastSeen`)多久"。

- `working` 任务超过**无活动阈值**(默认 15 分钟,`defaults write elf.busyelf inactivityTimeoutSeconds N`,下限 60s)→ 视为"**可能已断**",从阻塞集合中剔除、**放行休眠**。状态仍是 `working`(不谎报 done/失败、不弹横幅),popover 标灰 + "可能已断"。
- **完全可逆**:之后任一动词刷新 `lastSeen` → 自动恢复阻止休眠。这是"集合成员判定"的自然延伸(把判据从 `status==working` 改为 `status==working 且未超时`),仍不用整数计数。
- **实现满足 0 idle CPU**:用一个**仅在有 working 任务时存在**的一次性 `DispatchSourceTimer`,精确调度到"最近一个会超时/兜底清理的截止点"触发重算;无 working 任务即取消(放行后机器可休眠)。不是常驻轮询。
- 疑似已断的顶层任务若长期(默认 6h)仍无活动,在 `pruneLocked` 里兜底移除,防 `working` 项无界堆积。
- 用户也可随时在 UI 里**手动移除**(见下)。
- 好处:删掉了唯一的后台定时器,空闲时进程在 runloop 上真正睡死 → 坐实"0 idle CPU"。

**强制结束(force-stop)语义**:**只把任务从集合中移除(从而解除其对休眠的阻止),绝不杀任何进程。** UI 上是一个安静的 `×`,单段行内确认;若该任务看起来仍活跃(近期有 `update`),确认文案会警示。详见 [UX.md](UX.md)。

## 7. 资源策略(数 MB / 0 CPU)

- **事件驱动、零轮询**:服务器用 `Network.framework` `NWListener`,阻塞在 kqueue 上,两次请求之间进程真正休眠。
- **空闲无定时器**:无任何常驻后台轮询。两个 timer 都是按需存在、非轮询:
  - popover 内的 1s 计时器,**仅在 popover 打开时**存在,刷新已运行时长;
  - 看门狗一次性 timer(§6),**仅在有 `working` 任务时**存在,精确调度到截止点,无 working 任务即取消。此时机器本来就因阻止休眠而醒着,故不破坏"空闲 0 CPU"。
- **AppKit 而非 SwiftUI App** 作为外壳,避免 SwiftUI/Combine 把内存地板抬高。
- 不引入重型框架(无 Vapor/NIO;HTTP 手解析两个动词足矣)。
- App Nap:作为 UIElement 后台应用,持有电源断言期间行为正常;不做动画、不做 run-loop 忙等。

## 8. 安全

- **默认仅 loopback**:服务器用 `NWParameters` 设 `requiredInterfaceType = .loopback`——这才是"仅 loopback 可达"的来源(**不是** bind 到 `127.0.0.1`);loopback 免 macOS 本地网络隐私弹窗(TN3179)。
- **可选监听所有网口(0.0.0.0)**:右键菜单可切换(写 UserDefaults + 热重启监听);留默认 `.other`(SDK 的"无接口要求"哨兵)即绑全部接口。首次绑非回环会触发 TN3179 授权弹窗。供局域网内其它机器/容器上报任务。
- **不做鉴权**:纯本机、同用户场景,刻意保持简单。仅 loopback 时威胁模型仅限"本机同用户的其它进程伪造任务事件",影响有限(顶多让 Mac 多醒一会儿或提前睡)。**开启 0.0.0.0 后局域网可达且仍无鉴权**——`/claude/hooks` 永远只回空、不执行任何东西,最坏只是塞假任务/扰乱休眠,**仅在可信网络开启**。如未来需要,可加 per-install bearer token(注意 0600 token 对同用户进程不构成隔离)。

## 9. 数据模型

```swift
enum TaskStatus { case working, waiting }

struct TaskSession: Identifiable {
    let id: String              // 来自 agent 的 task/session id;字典 key
    var agent: String?          // 来源标签 "claude-code"/"codex";展示/分组
    var cwd: String?            // 工作目录;basename 作项目名(若适配器提供)
    var name: String            // 任务名/prompt(best-effort)
    var activity: String        // 当前工具+细节摘要(best-effort)
    var waitingMessage: String? // wait 时需要用户做什么
    var status: TaskStatus
    let startedAt: Date
    var lastSeen: Date
}
// 阻止休眠 = sessions.values.contains { $0.status == .working }
// 需要关注 = sessions.values.contains { $0.status == .waiting }
```

任务按 `id` 存(session id 多为 UUID,基本不撞);`agent` 留作展示/分组;需要更强隔离时可用 `agent:id` 复合键。

## 10. 模块划分(Xcode/SwiftPM 工程)

| 文件 | 职责 |
|---|---|
| `App/BusyElfApp.swift` | `@main`:`NSApplication`,`setActivationPolicy(.accessory)`,`app.run()`。无 SwiftUI App/Scene |
| `App/AppDelegate.swift` | 持有 `NSStatusItem` + `NSPopover` + server 生命周期;连 `TaskStore.onChange → 刷新图标`;左键 popover / 右键菜单 |
| `BusyElf-Info.plist` | `LSUIElement=1`、bundle id、最低 macOS 14.0(由 `project.yml` 经 XcodeGen 生成,gitignore) |
| `Power/SleepGuard.swift` | 单个引用计数的 `IOPMAssertion`;`setBlocked(Bool)`;可选第二个显示断言 |
| `State/TaskSession.swift` | `TaskSession` 值类型 + `TaskStatus` + `elapsed/isStuck` 辅助 |
| `State/TaskStore.swift` | 真相源 `[id: TaskSession]`;串行队列;`start/update/wait/end` 幂等 upsert/remove;`reconcile()` 驱动 SleepGuard + onChange |
| `Server/LoopbackServer.swift` | `NWListener`(loopback)、accept、手解析 HTTP、取 body;把 `Router.route` 返回的响应 body 回给客户端(v1 回 `{"ok":true}`,`/claude/hooks` 回空体) |
| `Server/TaskEvent.swift` | 中立 body 的容错解析(`id/name/tool/detail/message/reply/agent/cwd`) |
| `Server/Router.swift` | 路径分流 → 动词 → 调 `TaskStore`;`/claude/hooks` 走 Claude 适配,`/v1/task/*` 走中立 |
| `Server/ClaudeHookEvent.swift` | **内建 Claude 适配器**:把 Claude hook 原始 payload 按 `hook_event_name` 翻成中立动作(唯一懂 Claude 字段的文件) |
| `UI/StatusItemController.swift` | `refresh(workingCount:waitingCount:)`:bolt 明暗 + 数字 + 关注态(waiting 用 palette 烤橙 + 橙色数字) |
| `UI/PopoverController.swift` | 纯 AppKit `NSViewController`:状态头、可滚动任务列表、空态、底部开关;仅可见时的 1s 时长 ticker;⋯ overflow 菜单 |
| `UI/AgentRowView.swift` | 单任务行 `NSView`:状态点、项目名、任务/活动、时长、`×` 行内确认;按 id 复用 + hover 高亮 |
| `UI/AppKitHelpers.swift` | popover 公用控件:`DotView`(状态点)、`HoverButton`(hover 变红的 ×)、`HoverRow`/`ClickableRow`(悬停高亮 + 整行可点)、label/symbol/separator 工厂 |
| `UI/Notifier.swift` | `UNUserNotificationCenter`:working→waiting 时发横幅 |
| `Login/LoginItem.swift` | `SMAppService.mainApp` 注册/注销;默认关 |

## 11. UI/UX(摘要)

详见 [UX.md](UX.md)。要点:

- **图标**:单一 `bolt.fill`,靠**整只闪电着色**/明暗/数字变化(不换字形、不叠加小圆点,避免菜单栏抖动)。六档优先级高→低:不可达红 > 失败红 > 等待橙 > (无 working)完成绿 > 运行白 > 空闲灰。
- **popover**:状态头("Blocking sleep · 2 working" / "Idle")+ 可滚动任务行 + 底部设置("保持屏幕唤醒" + "更多设置"折叠区[开机启动/网口/端口/超时] + "Quit")。
- **提醒**:任务进入 waiting 时发系统横幅"🔔 <项目>:Claude 需要你处理"。
- **强制结束**:`×` 单段行内确认,只移除不杀进程,活跃任务有警示。
- 空态走"elf workbench"调性;诚实交代合盖仍会休眠。

## 12. 关键决策表

| 主题 | 选择 | 一句话理由 |
|---|---|---|
| UI 框架 | 全程纯 AppKit(含 popover,不链接 SwiftUI) | 需要图标数字徽标/左右键区分/程序化 popover;链 SwiftUI 会把 footprint 抬到 ~129MB |
| 阻止休眠 | `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` | == `caffeinate -i`;无子进程、崩溃自动回收、sandbox 安全 |
| 计数模型 | `id` 字典 + 幂等增删 | 事件会丢/重;整数计数器会永久卡住休眠 |
| 协议 | agent 中立的 6 动词 HTTP(start/update/wait/done/fail/remove) | 不绑 Claude;未来接 Codex 等只需写适配器;与 `/claude/hooks` 表现力对等 |
| Hook 传输 | Claude 走内建 `/claude/hooks`(HTTP hook,零依赖);通用走 `jq+curl`→`/v1/task/*` | `jq` 非人人有,内建适配体验更好;翻译隔离在一个文件,核心仍中立、不 ship 二进制 |
| 服务器 | `NWListener` loopback,事件驱动 | 0 空闲 CPU、零依赖、免本地网络隐私弹窗 |
| 崩溃自愈 | 不做存活探测;看门狗按"无活动超时"放行休眠 + 手动移除 | 既防丢事件永久卡住休眠,又不引入 PID/transcript 探测或常驻轮询 |
| 无活动看门狗 | 派生判定(`working` 且未超时)+ 仅在有 working 时存在的一次性 timer | 卡死任务自动放行休眠且可逆;0 idle CPU 不破 |
| 强制结束 | 仅移除任务,不杀进程 | 用户明确要求;沙盒/分发不再被绑死 |
| 配置 | UserDefaults(`defaults write elf.busyelf …`)+ 右键菜单;env 覆盖供测试 | 极致轻量,复用现成 NSMenu,无需独立设置窗口 |
| 鉴权 | 无(默认仅 loopback;可选 0.0.0.0) | 本机同用户从简;开 0.0.0.0 需自担局域网无鉴权风险 |
| 内存目标 | 实测 phys_footprint ≈ 12MB | 纯 AppKit(不链 SwiftUI)达成"数 MB";以 phys_footprint 而非 RSS 衡量 |
| 最低系统 | macOS 14.0 | SF Symbols / SMAppService |
| 分发 | Developer-ID + 公证,App Store 外 | 最省事;无沙盒约束需求 |

## 13. 实施阶段

- **P0 核心休眠环**:AppKit 外壳 + `LSUIElement` + `SleepGuard` + `TaskStore`(状态机)+ debug 菜单手动增删。用 `pmset -g assertions` 验证 0→1 加断言、1→0 释放。
- **P1 IPC + 适配器端到端**:`LoopbackServer`(loopback)+ `Router` 路径路由 + `TaskEvent` 容错解析 + Claude `settings.json`(jq 适配器)。真实会话翻转计数并阻止/恢复休眠。**先在真机抓各 hook 真实 payload,锁定 jq 字段。**
- **P2 动态图标 + popover(只读)**:图标明暗/数字/关注态;纯 AppKit popover 列表显示项目/任务/活动/时长。
- **P3 提醒 + 强制结束**:`wait` 态 UI、working→waiting 系统横幅、`×` 单段确认、Stop all。
- **P4 打磨发布**:开机启动(`SMAppService` 默认关)、"保持屏幕唤醒"、空态、`PROTOCOL.md`、Developer-ID 签名 + 公证、内存/CPU 审计。

## 14. 待确认 / 注意事项

- **Claude Code hook 字段名(已对照官方 hooks 参考锁定)**:prompt 文本字段就是 **`prompt`**;`PostToolUse` 看 `tool_name` + `tool_input.{command,file_path,…}`;`MessageDisplay` 看 `delta`/`index`;`Stop`/`SubagentStop`/`StopFailure` 看 `last_assistant_message`(及 `error`/`error_details`);subagent 看 `agent_id`/`agent_type`。即便某版本字段不同也只影响展示(降级即可),**打不进核心休眠逻辑**(逻辑只看 `hook_event_name` + `session_id`)。
- **读 `notification_type` 区分 permission vs idle**:原设计靠状态机时序区分、刻意不读该字段;现因终态(done/failed)留存展示、`wait` 改为总是 upsert 创建,时序不再可靠,故**改为显式读 `notification_type`**(`permission_prompt`→wait,`idle_prompt` 等→忽略)。官方已稳定提供该字段。
- **`jq` 现在可选**:推荐用内建 `/claude/hooks`(HTTP hook,零依赖);仍想用通用 jq+curl→`/v1/task/*` 的才需 `brew install jq`。
- **HTTP hook URL 写死端口**:`/claude/hooks` 的 URL 含默认 `17872`;若该端口被占用、BusyElf 回退到 17873+,需把 URL 端口同步改掉(与 jq 方案的 curl URL 同样限制)。可 `defaults write elf.busyelf httpPort N` 固定端口;右键菜单顶部显示实际监听地址。
- **运行期配置(AppConfig)**:`inactivityTimeoutSeconds`(看门狗阈值,默认 900,下限 60)、`httpPort`(默认 17872)、`listenAllInterfaces`(默认 false)。优先级 **环境变量 `BUSYELF_*` > UserDefaults > 默认**;env 层主要供测试/E2E,不污染用户 defaults。
- **多 agent 接入**(Codex CLI 等):各写适配器映射到同一套 6 动词;BusyElf 无需改动。
- **环境约束**:构建/签名/运行/真机验证均在 macOS 进行(已在 macOS 26 / Apple Silicon 真机编译、运行、验证通过)。
