# BusyElf 任务协议 v1

一套 **agent 无关**的本地 HTTP 协议。任何 agent 只要把自己的生命周期事件映射到下面六个动词,就能让 BusyElf 替它管理系统休眠与状态展示。BusyElf 服务端不包含任何特定 agent 的概念。

> 这套中立接口与内建的 Claude 专用端点 `/claude/hooks` **表现力对等**:子任务(subagent)、流式回复、完成/失败细节都能用通用语义字段表达。Claude 走专用端点只是更省事,不代表中立接口缺能力。

## 设计原则

- **中立**:字段是通用语义(`id` / `name` / `tool` / `message`),不是某个 agent 的字段名。
- **翻译在适配器层**:agent 原生字段 → 本协议字段的转换,由该 agent 的适配器(如 Claude Code 的 hook + jq)完成。
- **动词在路径**:语义由 URL 路径决定,而非 body 里的某个 `type` 字段——这样适配器为每个事件配一个固定 URL 即可,无需往 body 注入类型。
- **body 容错**:除 `id` 外字段全部可选;服务端解析不到只做展示降级,**绝不影响休眠逻辑**(休眠逻辑只依赖路径 + `id`)。

## 传输

- 本机回环:`http://127.0.0.1:17872`。**端口黏住(sticky)**:首启探测出一个可用端口(17872 被占就 17873/74/75,实在没有就让系统分配)并**持久化固定**,此后每次只用它——适配器 URL 写一次长期有效。该固定端口若某次被占,BusyElf **不漂移**,而是在 UI 报错(菜单栏红角标 + 面板横幅 [重试]/[改端口])。
  - 改端口:面板「更多设置」改,或 `defaults write elf.busyelf httpPort 12345` 后重开 BusyElf(=重新钉死;右键菜单/面板显示实际监听地址);改端口后需相应更新适配器 URL。
- 默认仅 loopback 可达(服务端 `NWParameters.requiredInterfaceType = .loopback`)。
  - 可在右键菜单勾「监听所有网口 (0.0.0.0)」让局域网内其它机器/容器上报任务;**首次会触发 macOS 本地网络隐私授权弹窗**。
- **无鉴权**(纯本机同用户场景)。**绑 0.0.0.0 后局域网可达且无鉴权**:`/claude/hooks` 永远只回空、不执行任何东西,最坏只是别人能塞假任务/让你的 Mac 不休眠——仅在可信网络开启。
- 方法:`POST`,`Content-Type: application/json`(服务端宽容,非 JSON 直接忽略)。
- 适配器应**快速失败**(短超时、吞错、退出码 0),确保 BusyElf 未运行时不阻塞 agent。

## 端点

所有动词除 `id` 外字段全可选。**子任务**:把子 id 折进 `id`(如 `"父id#子id"`)并带 `parentId`(= 父 id);有 `parentId` 即子任务。

### `POST /v1/task/start` — 开始任务

任务开始工作(一个新 turn 开始)。

```jsonc
{
  "id":       "string   // 必填:该 agent 内唯一的 task/session id(子任务 = '父id#子id')",
  "name":     "string?  // 任务名 / 子任务标签(如 'Explore'),用于展示",
  "prompt":   "string?  // 触发本轮的用户提示词",
  "parentId": "string?  // 父任务 id;非空即子任务",
  "agent":    "string?  // 来源标签,如 'claude-code' / 'codex'"
}
```
效果:upsert 该任务,`status = working`,记录 prompt / 子任务关联。出现首个 working 任务时**开始阻止系统休眠**。

### `POST /v1/task/update` — 任务更新

任务有进展(在干活)。也用作"等待/完成后恢复"的信号。

```jsonc
{
  "id":          "string   // 必填",
  "tool":        "string?  // 当前调用的工具名,如 'Bash' / 'Edit'",
  "toolInput":   "string?  // 工具细节,如命令或文件路径(同义 detail,优先 toolInput)",
  "reply":       "string?  // agent 回复文本(或增量)",
  "replyAppend": "bool?    // true=追加到现有回复,false/缺省=替换",
  "toolComplete": "bool? // true=当前动作(工具调用)已完成 → UI 在动作行打 ✓;缺省=进行中",
  "toolFailed": "bool?   // true=当前动作(工具调用)失败 → UI 在动作行改打 ✗(优先于 ✓);缺省=未失败",
  "toolError":  "string? // 当前动作失败原因(best-effort);仅作动作行 tooltip,不进可见正文",
  "parentId":    "string?  // 子任务关联(漏了 start 时也能把子任务建对)"
}
```
效果:upsert 该任务,`status = working`。若原为 `waiting`/`done`/`failed`,则**复活接管**(恢复阻止休眠、清除等待/失败痕迹)。刷新展示用的"当前动作"与回复。

> `toolComplete` / `toolFailed` 仅影响动作行的 ✓/✗ 展示,**不改变 status**:任务仍 `working`、仍阻止休眠;整任务的完成是 `done`、整任务的失败是 `fail`。
> 配对用法(对应 Claude 的 `PreToolUse`/`PostToolUse`):工具开始发 `toolComplete:false`、工具结束发 `toolComplete:true`。只发其一也可——只发结束即"做完才显示并打 ✓"。
> **工具失败**(对应 Claude 的 `PostToolUseFailure`):发 `toolFailed:true`(+ 可选 `toolError`)→ 动作行打 ✗。工具失败是 agent loop 里的常态、**不代表任务中断**,所以仍是 `update`/`working`,只是动作行的标记不同;真正的任务级失败用 `fail`。每条新动作(新 `tool`/`reply`)会覆盖上一条的 ✓/✗ 标记。

> upsert 语义是刻意的:即使漏收了 `start`(BusyElf 中途启动),一条 `update` 也能建/恢复任务、重新阻止休眠——**宁可多醒,不可漏醒**。
> 流式回复:`reply` + `replyAppend` 是通用 replace/append 原语——中立客户端直接发完整 `reply`(replace 即可)即可,无需增量概念。

### `POST /v1/task/wait` — 等待用户输入

任务被阻塞,需要用户处理交互(权限请求、追问等)。

```jsonc
{
  "id":      "string   // 必填",
  "message": "string?  // 需要用户做什么,直接展示给用户"
}
```
效果:upsert 该任务,置 `status = waiting`,记录 `message`,**点亮"需要关注"**(图标提示 + 发系统横幅)。`waiting` 任务**不阻止休眠**(等人不算干活)。

> 中立 `wait` 总是创建(满足"见到一个请求就追踪")。Claude 适配器靠 `notification_type` 区分:只在 `permission_prompt`(真等待)时调 wait,`idle_prompt`(turn 后空闲)根本不调——避免幽灵等待项。

### `POST /v1/task/done` — 任务完成

任务正常结束(turn 完成 / 子任务完成 / 会话优雅退出)。**不移除**,转为"已完成"终态。

```jsonc
{
  "id":    "string   // 必填",
  "reply": "string?  // agent 最终回复摘要"
}
```
效果:**仅当该任务已存在时**,置 `status = done`(failed 不被覆盖)。完成项**不阻止休眠**,留在 popover 里:打开看一次(菜单栏绿色提示),下次打开自动清理。

### `POST /v1/task/fail` — 任务失败

任务异常停止(如 API 错误)。

```jsonc
{
  "id":          "string   // 必填",
  "errorKind":   "string?  // 失败类型,如 'rate_limit' / 'overloaded'",
  "errorDetail": "string?  // 失败细节 / 错误原文",
  "reply":       "string?  // 失败前的回复(可选)"
}
```
效果:upsert 该任务,置 `status = failed`(失败优先,覆盖 done)。失败项**不阻止休眠**,菜单栏**红色紧急提示**持续到该 failed 项被清理/移除;打开 popover 展示原因与细节。

### `POST /v1/task/remove` — 移除任务

用户主动移除(或客户端确实想丢弃)。

```jsonc
{
  "id": "string   // 必填"
}
```
效果:移除该任务及其子任务(幂等;不存在也无妨)。若移除后再无 `working` 任务,**恢复系统休眠**。

## 状态机

```
            start / update / wait / fail        ┌── update/start ──┐ (复活)
   (不存在) ───────────────────────────▶ working ◀──────────────────┘
       ▲                          wait │ │ │ done                ▲
       │ remove        ┌───────────────┘ │ └──────────┐          │ update/start
       │               ▼                 │ fail        ▼          │
       └── (移除) ── waiting ────────────┼──────────▶ done ───────┘
                                          ▼          (终态,留存提示)
                                       failed ───────────────────┘
                          (终态:不阻止休眠;打开看一次后清理)
```

活动态 `working` / `waiting`;终态 `done`(完成)/ `failed`(失败)。终态**留在字典里展示**、不阻止休眠,靠 seen 生命周期清理(打开 popover 标 seen,关闭后清),并有 TTL/数量兜底。

| 动词 | 不存在 | working | waiting | done | failed |
|---|---|---|---|---|---|
| `start`  | 创建→working | 刷新→working | 恢复→working | 复活→working | 复活→working |
| `update` | 创建→working | 刷新→working | **恢复→working** | 复活→working | 复活→working |
| `wait`   | 创建→waiting | →waiting | 刷新→waiting | 复活→waiting | 复活→waiting |
| `done`   | 忽略 | →done | →done | 刷新 reply | **忽略**(不覆盖失败) |
| `fail`   | 创建→failed | →failed | →failed | →failed | 刷新细节 |
| `remove` | 忽略(幂等) | 移除(级联子) | 移除 | 移除 | 移除 |

派生量:
- **阻止系统 idle 休眠** ⟺ 存在任一 `working` 任务(终态不阻止),**且该任务未"疑似已断"**(见下)。
- **需要用户关注**(图标橙 + 横幅) ⟺ 存在任一 `waiting` 任务。
- **完成提示**(图标绿) ⟺ 存在未看过的 `done`。**失败提示**(图标红,优先级最高) ⟺ 存在任一 `failed`(看过后仍红,直到清理/移除)。

## 看门狗:无活动超时 → 放行休眠

事件投递可能因任一环节出 bug / 丢失而漏发 `done`/`fail`,使任务卡在 `working` **永久阻止休眠**(本 app 绝不能有的 bug)。看门狗兜底:

- `working` 任务超过**无活动阈值**(`lastSeen` 起算,默认 15 分钟,可配)未收到任何动词 → 视为"**可能已断**",**不再阻止休眠**。状态仍是 `working`(不谎报 done/失败,不弹横幅),popover 中标灰 + "可能已断"。
- **完全可逆**:之后任一动词刷新 `lastSeen` → 自动恢复阻止休眠。
- 实现上是派生判定(`working` 且 `now − lastSeen > timeout`),配合一个**仅在有 working 任务时存在**的一次性定时器精确到截止点触发重算;无 working 任务即取消(idle 0 CPU)。
- 阈值配置:`defaults write elf.busyelf inactivityTimeoutSeconds 900`(下限 60s)后重开。
- 疑似已断的顶层任务若长期(默认 6h)仍无活动,兜底移除以防 `working` 项无界堆积。

## 幂等与可靠性

- 事件投递视为 **at-least-once 且可能丢失**。协议按"集合成员"而非"+1/−1 计数"设计,因此重复或丢失事件不会让计数漂移。
- 无主动存活探测,但有上面的**看门狗**兜底:agent 硬崩溃(SIGKILL/掉电)没发 `done`/`fail` 时,任务会在无活动超时后停止阻止休眠;用户也可在 UI 里手动移除。

## 示例(裸 curl,字段已是中立格式)

```bash
# 开始
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start \
  -d '{"id":"sess-123","prompt":"重构 auth 模块","agent":"claude-code"}'

# 更新(当前工具)
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/update \
  -d '{"id":"sess-123","tool":"Bash","toolInput":"npm test"}'

# 子任务
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start \
  -d '{"id":"sess-123#sub1","parentId":"sess-123","name":"Explore"}'
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/done \
  -d '{"id":"sess-123#sub1","reply":"扫描完成"}'

# 等待用户
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/wait \
  -d '{"id":"sess-123","message":"需要授权运行 Bash 命令"}'

# 完成 / 失败
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/done \
  -d '{"id":"sess-123","reply":"已修复并提交"}'
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/fail \
  -d '{"id":"sess-123","errorKind":"rate_limit","errorDetail":"API Error: Rate limit reached"}'

# 移除(用户主动)
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/remove \
  -d '{"id":"sess-123"}'
```

实际接入时,字段翻译由适配器完成。Claude Code 适配器见 [adapters/claude-code.md](adapters/claude-code.md)。

## 内建适配器端点(便捷,不破坏中立)

除了上面 agent 中立的 `/v1/task/*`,BusyElf 还内建了一个 **Claude Code 专属便捷端点**:

### `POST /claude/hooks` — Claude Code hook 入口

直接接收 Claude Code **HTTP hook**(`type: "http"`)发来的**原始 hook payload**,在服务端按 `hook_event_name` 翻成上面的六个动词。好处:用户无需在 hook 里写 `jq`+`curl`(很多人没装 `jq`),配置就是把各 hook 指向这一个 URL。

- **不改变中立核心**:Claude 专属知识(字段名、事件→动词映射)全部隔离在服务端一个文件([`ClaudeHookEvent.swift`](../Sources/BusyElf/Server/ClaudeHookEvent.swift)),`TaskStore` 与协议状态机一行不变、永不 import Claude 概念。它就是"把方式 B 的 jq 翻译搬进了 Swift"。
- **响应**:始终回 `2xx + 空 body`(Claude 把"2xx 空体"视为无操作,等同退出码 0 无输出)——BusyElf 是纯被动观察者,绝不阻止工具/注入上下文/改 Claude 流程。
- **容错**:与 `/v1/task/*` 同档,非 JSON / 缺 `session_id` / 未知事件一律静默忽略,仍回 200。
- 详见 [adapters/claude-code.md](adapters/claude-code.md)。其它 agent 仍走通用 `/v1/task/*`;是否为某个 agent 再加这种便捷端点,取决于它是否值得作"一等公民"。

## 编写一个新适配器(如 Codex CLI)

1. 找出该 agent 的"任务开始 / 有进展 / 等待用户 / 正常完成 / 异常失败 / 移除"原生信号。
2. 把每类信号映射成对应动词的 HTTP POST,body 填上能拿到的中立字段(至少 `id`)。
3. 用该 agent 自己的 id(session/task id)作 `id`,并带上 `agent` 标签便于展示。子任务把子 id 折进 `id` 并带 `parentId`。
4. 保证调用快速失败、不阻塞 agent。

## 版本

`/v1/` 前缀预留演进空间。未来若增删字段或动词,通过新版本前缀引入,保持 v1 兼容。
