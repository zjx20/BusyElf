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
   适配器层(每个 agent 各自一份;做字段翻译)
        │  HTTP POST  /v1/task/{start|update|wait|end}  (中立 body)
        ▼
   ┌──────────────── BusyElf.app (单进程, 纯 AppKit, LSUIElement) ─────────────┐
   │  LoopbackServer (NWListener, 127.0.0.1, 事件驱动)                          │
   │        │ 按路径路由到动词 + 容错解析 body                                  │
   │        ▼                                                                  │
   │  TaskStore  [id: TaskSession]  串行队列, 幂等 upsert/remove                │
   │        │ reconcile()                                                      │
   │        ├──▶ SleepGuard   (存在 working 任务 → 持有 1 个 IOPMAssertion)     │
   │        ├──▶ StatusItem   (图标: 数量 / working / 需要关注)                 │
   │        ├──▶ Popover      (SwiftUI, 仅在打开时渲染)                         │
   │        └──▶ Notifier     (working→waiting 时发系统横幅)                    │
   └──────────────────────────────────────────────────────────────────────────┘
```

**关键取舍:纯 AppKit,而非 SwiftUI `MenuBarExtra`。** 因为需要在图标旁画数字徽标、区分左键 popover / 右键菜单、程序化开关 popover——这些 `MenuBarExtra` 都做不到;且 AppKit 内存地板(~13MB RSS)显著低于 SwiftUI(~30–56MB),对省内存硬需求是决定性的。SwiftUI 仅用在 popover 内部(`NSHostingController`)。

- 最低系统:**macOS 14.0**(更好的 SF Symbols 渲染、现代 `SMAppService`)。
- 分发:**Developer-ID 签名 + 公证,App Store 外分发**(推荐;由于不杀进程,沙盒与否不再被强约束,Developer-ID 最省事)。
- **不捆绑任何 helper 二进制**:适配器用用户自带的 `jq` + `curl` 在 hook 里完成,BusyElf 只是个被动的 HTTP 服务端。
- 内存预期:接受 **~13MB RSS** 作为"数 MB"的现实落点(任何带菜单栏 UI 的 AppKit 应用都有此地板,真正单位数 MB 在有 UI 前提下做不到)。

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

可选增强:"也保持屏幕唤醒"开关 → 额外持有一个 `kIOPMAssertionTypePreventUserIdleDisplaySleep` 断言。

## 4. 中立协议(摘要)

BusyElf 只认识"任务",不认识任何具体 agent。详见 [PROTOCOL.md](PROTOCOL.md)。四个动词:

| Endpoint | 含义 | 主要字段 | 状态效果 |
|---|---|---|---|
| `POST /v1/task/start`  | 开始任务 | `id`*、`name?`、`agent?` | → **working** |
| `POST /v1/task/update` | 任务更新 | `id`*、`tool?`、`detail?`、`reply?` | → **working**(waiting 时重新接管) |
| `POST /v1/task/wait`   | 等待用户输入 | `id`*、`message?` | → **waiting** |
| `POST /v1/task/end`    | 结束任务 | `id`* | 移除任务 |

所有 agent 专属知识(字段名、事件语义)都下沉到适配器层;BusyElf 服务端永不 import 一个具体 agent 的概念。

## 5. 任务状态机

每个任务的状态:`status ∈ { working, waiting }`,加若干展示字段。

派生量:
- **阻止休眠** = 存在任一 `working` 任务。
- **需要关注** = 存在任一 `waiting` 任务。

动词 → 状态转移(注意 upsert 规则的刻意不对称):

| 动词 | 规则 | 理由 |
|---|---|---|
| `start`  | **upsert** → working | 任务开始 |
| `update` | **upsert** → working;若原为 waiting 则恢复 | 既是"在干活"心跳,也是 waiting→working 的恢复信号。**upsert**:即使漏掉了 start 也能恢复,**宁可多醒不可漏醒** |
| `wait`   | **仅更新已存在的任务** → waiting(无此任务则忽略) | 避免"任务已结束后又来一条 wait"产生幽灵等待项 |
| `end`    | 移除(幂等) | 任务结束 |

> 对 Claude Code 的体现:`update` 的"upsert/恢复"正是"Notification 后第一个 PostToolUse 当作用户已响应、重新接管休眠";`wait` 的"仅更新已存在"正好让 turn 结束后(`Stop` 已移除任务)才触发的 `idle_prompt` 通知被自然忽略——**因此不依赖有争议的 `notification_type` 字段**。

幂等设计的原因:事件投递是 at-least-once 且可能丢失。用集合成员而非 `+1/-1` 整数计数器——整数会漂移成负数或卡在正数从而**永久阻止休眠**,这是本应用绝不能有的 bug。

## 6. 崩溃处理与强制结束

**不做任何自动"存活探测"**:不取 PID、不看 transcript mtime、不跑后台 sweep 定时器。BusyElf 完全信任适配器/hook 的事件。

- 正常结束:`end`(包括 agent 优雅退出)→ 任务移除,计数准确。
- 硬崩溃(agent 被 SIGKILL / 掉电,没发 `end`):该任务残留 → 持续阻止休眠。**这是小概率事件,靠用户在 UI 里手动移除解决**(见下)。
- 好处:删掉了唯一的后台定时器,空闲时进程在 runloop 上真正睡死 → 坐实"0 idle CPU"。

**强制结束(force-stop)语义**:**只把任务从集合中移除(从而解除其对休眠的阻止),绝不杀任何进程。** UI 上是一个安静的 `×`,单段行内确认;若该任务看起来仍活跃(近期有 `update`),确认文案会警示。详见 [UX.md](UX.md)。

## 7. 资源策略(数 MB / 0 CPU)

- **事件驱动、零轮询**:服务器用 `Network.framework` `NWListener`,阻塞在 kqueue 上,两次请求之间进程真正休眠。
- **空闲无定时器**:没有任何后台 timer(自愈逻辑已删)。唯一的 timer 是 popover 内的 1s 计时器,**仅在 popover 打开时**存在,用于刷新已运行时长。
- **AppKit 而非 SwiftUI App** 作为外壳,避免 SwiftUI/Combine 把内存地板抬高。
- 不引入重型框架(无 Vapor/NIO;HTTP 手解析两个动词足矣)。
- App Nap:作为 UIElement 后台应用,持有电源断言期间行为正常;不做动画、不做 run-loop 忙等。

## 8. 安全

- 服务器用 `NWParameters` 设 `requiredInterfaceType = .loopback`——这才是"仅 loopback 可达"的来源(**不是** bind 到 `127.0.0.1`);loopback 免 macOS 本地网络隐私弹窗(TN3179)。
- **不做鉴权**:纯本机、同用户场景,刻意保持简单。威胁模型仅限"本机同用户的其它进程伪造任务事件",影响有限(顶多让 Mac 多醒一会儿或提前睡)。如未来需要,可加 per-install bearer token(注意 0600 token 对同用户进程不构成隔离)。

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
| `App/Info.plist` | `LSUIElement=1`、bundle id、最低 macOS 14.0 |
| `Power/SleepGuard.swift` | 单个引用计数的 `IOPMAssertion`;`setBlocked(Bool)`;可选第二个显示断言 |
| `State/TaskSession.swift` | `TaskSession` 值类型 + `TaskStatus` + `elapsed/isStuck` 辅助 |
| `State/TaskStore.swift` | 真相源 `[id: TaskSession]`;串行队列;`start/update/wait/end` 幂等 upsert/remove;`reconcile()` 驱动 SleepGuard + onChange |
| `Server/LoopbackServer.swift` | `NWListener`(loopback)、accept、手解析 `POST /v1/task/*`、取 body |
| `Server/TaskEvent.swift` | 中立 body 的 `Codable`(`id/name/tool/detail/message/reply/agent`)+ 容错解析 |
| `Server/Router.swift` | 路径 → 动词 → 调 `TaskStore` |
| `UI/StatusItemController.swift` | `refreshIcon(count, hasWaiting)`:bolt 明暗 + 数字 + 关注态着色 |
| `UI/PopoverRootView.swift` | SwiftUI 根视图:状态头、可滚动任务列表、底部开关 |
| `UI/AgentRow.swift` | 单任务行:状态点、项目名、任务/活动、时长、`×` 行内确认 |
| `UI/PopoverViewModel.swift` | `TaskStore` 快照桥接;仅可见时的时长 ticker |
| `UI/Notifier.swift` | `UNUserNotificationCenter`:working→waiting 时发横幅 |
| `Login/LoginItem.swift` | `SMAppService.mainApp` 注册/注销;默认关 |

## 11. UI/UX(摘要)

详见 [UX.md](UX.md)。要点:

- **图标**:单一 `bolt.fill`,靠明暗/数字/着色变化(不换字形,避免菜单栏抖动)。N=0 半透明无数字;有 working 全亮 + 数字;有 waiting 着色 + 提示。
- **popover**:状态头("Blocking sleep · 2 working" / "Idle")+ 可滚动任务行 + 底部开关("也保持屏幕唤醒""开机启动""Quit")。
- **提醒**:任务进入 waiting 时发系统横幅"🔔 <项目>:Claude 需要你处理"。
- **强制结束**:`×` 单段行内确认,只移除不杀进程,活跃任务有警示。
- 空态走"elf workbench"调性;诚实交代合盖仍会休眠。

## 12. 关键决策表

| 主题 | 选择 | 一句话理由 |
|---|---|---|
| UI 框架 | 纯 AppKit(SwiftUI 仅在 popover 内) | 需要图标数字徽标/左右键区分/程序化 popover;内存更低 |
| 阻止休眠 | `IOPMAssertionCreateWithName(PreventUserIdleSystemSleep)` | == `caffeinate -i`;无子进程、崩溃自动回收、sandbox 安全 |
| 计数模型 | `id` 字典 + 幂等增删 | 事件会丢/重;整数计数器会永久卡住休眠 |
| 协议 | agent 中立的 4 动词 HTTP | 不绑 Claude;未来接 Codex 等只需写适配器 |
| Hook 传输 | 适配器内 `jq + curl` 直调 HTTP | 不 ship 二进制;字段翻译留在适配器层 |
| 服务器 | `NWListener` loopback,事件驱动 | 0 空闲 CPU、零依赖、免本地网络隐私弹窗 |
| 崩溃自愈 | 不做自动探测;靠手动移除 | 小概率;换取零后台定时器 |
| 强制结束 | 仅移除任务,不杀进程 | 用户明确要求;沙盒/分发不再被绑死 |
| 鉴权 | 无 | 纯本机同用户,刻意从简 |
| 内存目标 | 接受 ~13MB | 带 UI 的 AppKit 现实地板 |
| 最低系统 | macOS 14.0 | SF Symbols / SMAppService |
| 分发 | Developer-ID + 公证,App Store 外 | 最省事;无沙盒约束需求 |

## 13. 实施阶段

- **P0 核心休眠环**:AppKit 外壳 + `LSUIElement` + `SleepGuard` + `TaskStore`(状态机)+ debug 菜单手动增删。用 `pmset -g assertions` 验证 0→1 加断言、1→0 释放。
- **P1 IPC + 适配器端到端**:`LoopbackServer`(loopback)+ `Router` 路径路由 + `TaskEvent` 容错解析 + Claude `settings.json`(jq 适配器)。真实会话翻转计数并阻止/恢复休眠。**先在真机抓各 hook 真实 payload,锁定 jq 字段。**
- **P2 动态图标 + popover(只读)**:图标明暗/数字/关注态;SwiftUI popover 列表显示项目/任务/活动/时长。
- **P3 提醒 + 强制结束**:`wait` 态 UI、working→waiting 系统横幅、`×` 单段确认、Stop all。
- **P4 打磨发布**:开机启动(`SMAppService` 默认关)、"也保持屏幕唤醒"、空态、`PROTOCOL.md`、Developer-ID 签名 + 公证、内存/CPU 审计。

## 14. 待确认 / 注意事项

- **Claude Code hook 字段名需真机确认**:`UserPromptSubmit` 的 prompt 字段叫 `prompt` 还是 `prompt_text`、`SessionEnd` 的 `reason`/`end_reason` 等,多轮 web 核实**自相矛盾**,**不要凭记忆硬编码**。好在这些只影响适配器层的 jq 与展示(降级即可),**打不进核心休眠逻辑**(逻辑只看路径 + `id`)。P1 用 `cat >> ~/busyelf-hook-capture.ndjson` 抓一遍即可锁定。
- **`notification_type` 不可靠**:多数核实显示该字段实际不下发(#11964 closed-not-planned)。本设计**不依赖**它(靠状态机时序区分 permission vs idle)。
- **`jq` 依赖**:Claude 适配器需要用户安装 `jq`(`brew install jq`)。它是用户自带工具,非我们 ship 的 helper。
- **多 agent 接入**(Codex CLI 等):各写适配器映射到同一套 4 动词;BusyElf 无需改动。
- **环境约束**:当前 Linux dev container 无法编译/运行 macOS 应用;构建/签名/运行在 macOS 上进行。
