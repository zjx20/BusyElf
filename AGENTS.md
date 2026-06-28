# AGENTS.md — 给 AI agent 的工作指南

BusyElf 是一个**极致轻量的原生 macOS 菜单栏常驻 app**:有 AI agent(Claude Code / Codex 等)在跑长任务时**阻止系统休眠**,任务结束后恢复;菜单栏图标实时显示在干活/等待/完成/失败,popover 列出每个任务。它通过一套 **agent 无关的本地 HTTP 协议**接收事件,本身不绑定任何工具。

读这份就够上手。深入细节见 `docs/`(末尾有索引)。

---

## ⚠️ 硬约束(改动前必读,违反即破坏产品定位)

1. **纯 AppKit,永不链接 SwiftUI**。这是 12MB footprint 的关键(若 popover 用 SwiftUI,phys_footprint 飙到 ~129MB)。UI 全部手写 AppKit,见 `Sources/BusyElf/UI/`。不要 `import SwiftUI`、不要用 `@State`/`some View`。
2. **休眠正确性 > 一切**。阻止休眠 ⟺ 存在任一 `working` 任务。
   - 用**集合成员**(`[id: TaskSession]` 字典)判断,**绝不用 `+1/-1` 整数计数**——事件 at-least-once 且可能丢失/乱序,整数会漂移成负数或卡正 → **永久阻止休眠**(本 app 绝不能有的 bug)。
   - **body 解析失败绝不能影响休眠逻辑**。休眠只看 路径(动词)+ `id`;其它字段解析不到只做展示降级。
   - 宁可多醒不可漏醒:漏 `start` 也能靠 `update`/`wait`/`fail` 的 upsert 接管(中途启动)。
3. **agent 中立核心**。`TaskStore` / 协议核心**永不 import 任何特定 agent 的概念**。所有"懂 Claude 字段名/事件语义"的代码**只允许**待在 `Server/ClaudeHookEvent.swift` 一个文件里。新增其它 agent 适配也照此隔离。
4. **`/claude/hooks` 永远回 `2xx + 空 body`**。BusyElf 是纯被动观察者:绝不向 agent 注入上下文、不阻止工具、不改流程。
5. **菜单栏图标绝不替换字形**(`bolt.fill` 固定)。换字形会改宽度让菜单栏抖动。状态靠 着色 / 数字 / 透明度 / 右上角合成角标 传达。见 `UI/StatusItemController.swift`。
6. **idle 0 CPU**。服务端事件驱动(`NWListener`,kqueue 阻塞);popover 的 1s ticker 仅在可见时运行。别引入轮询/常驻定时器。
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
- `reconcile()` 三件事:`SleepGuard.setBlocked(hasWorking)`、主线程派发排序快照、`→waiting`/`→failed` 跳变发系统横幅(去抖)。
- UI 只读快照重绘(`PopoverController.rebuild()` 按 id 复用行对象)。

---

## 协议(六动词)与状态机

中立端点 `POST /v1/task/{start,update,wait,done,fail,remove}`;除 `id` 外字段全可选、容错降级。

| 动词 | 效果 |
|---|---|
| `start`  | upsert→working;记 prompt / 子任务标签(name)/ parentId;新 turn 清旧回复 |
| `update` | upsert→working,**复活终态/waiting**;刷新当前动作(tool 优先,退化 reply)与回复(`reply`+`replyAppend` replace/append) |
| `wait`   | upsert→waiting(总是创建);放行休眠 + 点亮"需要关注" |
| `done`   | 已存在→done(终态,不删,留绿点提示);failed 不被覆盖 |
| `fail`   | upsert→failed(失败优先;红点);记 errorKind/errorDetail |
| `remove` | 真正移除(级联子任务) |

`status ∈ {working, waiting, done, failed}`。`working` 阻止休眠;`waiting/done/failed` 放行。终态留存展示,靠 **seen 生命周期**清理:打开 popover→`markTerminalSeen`(清角标),关闭→`purgeSeenTerminal`(下次打开消失);另有 TTL/数量上限兜底(`pruneLocked`)。

**子任务(subagent)**:把子 id 折进 `id`(`"父id#子id"`)+ `parentId` 表达;有 `parentId` 即子任务。折叠只发生在适配器边界,核心层无感。

**Claude 适配映射**(`ClaudeHookEvent.swift`):`UserPromptSubmit`→start、`SubagentStart`→start(子)、`PostToolUse`→update、`MessageDisplay`→update(reply)、`Notification`(读 `notification_type`:permission→wait / idle→忽略)、`Stop`/`SubagentStop`/`SessionEnd`→done、`StopFailure`→fail。subagent 靠 `agent_id`/`agent_type`,**session_id 与父相同**。

---

## 构建 / 运行 / 测试(全 CLI,永不打开 Xcode)

`project.yml`(XcodeGen)是工程**唯一真相源**;`.xcodeproj` 由它生成、**gitignore、从不手改**。

```bash
# 构建 + 运行
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
- **改 UI**:复用 `UI.label/DotView/HoverRow/ClickableRow`(`UI/AppKitHelpers.swift`)、`Format.duration/ago`。

每加一处行为,**在两个测试脚本里补断言**(E2E 断 `/debug/state`,单元断内部逻辑)。

---

## 调试教训(踩过的坑)

- **反复推理框架行为失败时,立刻插桩测量,别接着猜。** popover "撑大缩不回" 曾改了 4 轮(fittingSize 时机 / 表头 hugging / compression resistance)都没消失——全是基于"看似合理"的推理。真凶(`view.fittingSize` 含 `NSScrollView` + 隐藏 `emptyView` 时**恒返回错值**)是加一行 `NSLog` 打出 `listFrameH/constraint/fittingH` 后**一眼看出**的。**对 AutoLayout / fittingSize / NSStackView 这类行为别凭脑补下"根因"结论;打日志看真实数值。**
- **含 `NSScrollView` 的层级,别用 `view.fittingSize` 求 popover 高度。** 滚动视图设计上就"内容任意大、自己滚动",不会把内容高报成自身尺寸。要"列表跟内容长但封顶 320 then 滚动",必须**自己量** `listStack`(普通 stack)的真实高度、取 `min(,320)` 写进 scrollView 的**显式高度约束**,再**逐项求和**(header/footer/分隔线各自 intrinsic + 内容区)算出 `preferredContentSize`。见 `PopoverController.syncContentSize`。
- **行高会变的 UI 别切换到"另一处的更高视图"**(易被裁)。就地原地变换(如 × 原地换成确认按钮),高度不变最稳。

## 约定

- 注释用**中文**,与现有风格一致;命名/缩进/惯用法贴合周边代码。
- 端口默认 `17872`,被占用回退 `17873/17874/17875`(`LoopbackServer.candidatePorts`);适配器 URL 写死默认端口,文档已提示回退。
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
| `docs/BUILD.md` | 纯 CLI 构建/签名/公证 + **测试**说明 |
| `docs/claude-code-hooks.md` | Claude Code hooks 官方参考(权威字段来源) |
