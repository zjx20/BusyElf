# BusyElf 任务协议 v1

一套 **agent 无关**的本地 HTTP 协议。任何 agent 只要把自己的生命周期事件映射到下面四个动词,就能让 BusyElf 替它管理系统休眠与状态展示。BusyElf 服务端不包含任何特定 agent 的概念。

## 设计原则

- **中立**:字段是通用语义(`id` / `name` / `tool` / `message`),不是某个 agent 的字段名。
- **翻译在适配器层**:agent 原生字段 → 本协议字段的转换,由该 agent 的适配器(如 Claude Code 的 hook + jq)完成。
- **动词在路径**:语义由 URL 路径决定,而非 body 里的某个 `type` 字段——这样适配器为每个事件配一个固定 URL 即可,无需往 body 注入类型。
- **body 容错**:除 `id` 外字段全部可选;服务端解析不到只做展示降级,**绝不影响休眠逻辑**(休眠逻辑只依赖路径 + `id`)。

## 传输

- 本机回环:`http://127.0.0.1:17872`(端口可配置;被占用时回退到其它端口,并需相应更新适配器 URL)。
- 仅 loopback 可达(服务端 `NWParameters.requiredInterfaceType = .loopback`)。
- **无鉴权**(纯本机同用户场景)。
- 方法:`POST`,`Content-Type: application/json`(服务端宽容,非 JSON 直接忽略)。
- 适配器应**快速失败**(短超时、吞错、退出码 0),确保 BusyElf 未运行时不阻塞 agent。

## 端点

### `POST /v1/task/start` — 开始任务

任务开始工作。

```jsonc
{
  "id":    "string   // 必填:该 agent 内唯一的 task/session id",
  "name":  "string?  // 任务名或用户 prompt,用于展示",
  "agent": "string?  // 来源标签,如 'claude-code' / 'codex'"
}
```
效果:upsert 该任务,`status = working`。出现首个 working 任务时**开始阻止系统休眠**。

### `POST /v1/task/update` — 任务更新

任务有进展(在干活)。也用作"等待用户输入后恢复"的信号。

```jsonc
{
  "id":     "string   // 必填",
  "tool":   "string?  // 当前调用的工具名,如 'Bash' / 'Edit'",
  "detail": "string?  // 工具细节,如命令或文件路径",
  "reply":  "string?  // agent 最新文本回复"
}
```
效果:upsert 该任务,`status = working`。若原为 `waiting`,则**重新接管**(恢复阻止休眠、清除"需要关注")。刷新展示用的"当前工作"。

> upsert 语义是刻意的:即使漏收了 `start`,一条 `update` 也能恢复任务、重新阻止休眠——**宁可多醒,不可漏醒**。

### `POST /v1/task/wait` — 等待用户输入

任务被阻塞,需要用户处理交互(权限请求、追问等)。

```jsonc
{
  "id":      "string   // 必填",
  "message": "string?  // 需要用户做什么,直接展示给用户"
}
```
效果:**仅当该任务已存在时**,置 `status = waiting`,记录 `message`,**点亮"需要关注"**(图标提示 + 发系统横幅)。`waiting` 任务**不阻止休眠**(等人不算干活)。
若该 `id` 不存在则**忽略**(避免任务结束后迟到的等待通知产生幽灵项)。

### `POST /v1/task/end` — 结束任务

任务结束(正常完成、被取消、或 agent 退出)。

```jsonc
{
  "id": "string   // 必填"
}
```
效果:移除该任务(幂等;不存在也无妨)。若移除后再无 `working` 任务,**恢复系统休眠**。

## 状态机

```
                 start / update
   (不存在) ──────────────────────▶ working ◀───────┐
       ▲                              │  │           │ update
       │ end                     wait │  │ end       │ (恢复)
       │                              ▼  ▼           │
       └────────────── (移除) ◀──── waiting ─────────┘
                                  (wait 仅作用于已存在任务)
```

| 动词 | 不存在时 | working 时 | waiting 时 |
|---|---|---|---|
| `start`  | 创建→working | 刷新→working | 恢复→working |
| `update` | 创建→working | 刷新→working | **恢复→working** |
| `wait`   | **忽略** | →waiting | 刷新→waiting |
| `end`    | 忽略(幂等) | 移除 | 移除 |

派生量:
- **阻止系统 idle 休眠** ⟺ 存在任一 `working` 任务。
- **需要用户关注**(图标提示 + 横幅) ⟺ 存在任一 `waiting` 任务。

## 幂等与可靠性

- 事件投递视为 **at-least-once 且可能丢失**。协议按"集合成员"而非"+1/−1 计数"设计,因此重复或丢失事件不会让计数漂移。
- 无自动存活探测:若 agent 硬崩溃(SIGKILL/掉电)没发 `end`,任务会残留并持续阻止休眠。由用户在 UI 里手动移除该任务解除。

## 示例(裸 curl,字段已是中立格式)

```bash
# 开始
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start \
  -d '{"id":"sess-123","name":"重构 auth 模块","agent":"claude-code"}'

# 更新
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/update \
  -d '{"id":"sess-123","tool":"Bash","detail":"npm test"}'

# 等待用户
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/wait \
  -d '{"id":"sess-123","message":"需要授权运行 Bash 命令"}'

# 结束
curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/end \
  -d '{"id":"sess-123"}'
```

实际接入时,字段翻译由适配器完成。Claude Code 适配器见 [adapters/claude-code.md](adapters/claude-code.md)。

## 内建适配器端点(便捷,不破坏中立)

除了上面 agent 中立的 `/v1/task/*`,BusyElf 还内建了一个 **Claude Code 专属便捷端点**:

### `POST /claude/hooks` — Claude Code hook 入口

直接接收 Claude Code **HTTP hook**(`type: "http"`)发来的**原始 hook payload**,在服务端按 `hook_event_name` 翻成上面的 4 动词。好处:用户无需在 hook 里写 `jq`+`curl`(很多人没装 `jq`),配置就是把各 hook 指向这一个 URL。

- **不改变中立核心**:Claude 专属知识(字段名、事件→动词映射)全部隔离在服务端一个文件([`ClaudeHookEvent.swift`](../Sources/BusyElf/Server/ClaudeHookEvent.swift)),`TaskStore` 与协议状态机一行不变、永不 import Claude 概念。它就是"把方式 B 的 jq 翻译搬进了 Swift"。
- **响应**:始终回 `2xx + 空 body`(Claude 把"2xx 空体"视为无操作,等同退出码 0 无输出)——BusyElf 是纯被动观察者,绝不阻止工具/注入上下文/改 Claude 流程。
- **容错**:与 `/v1/task/*` 同档,非 JSON / 缺 `session_id` / 未知事件一律静默忽略,仍回 200。
- 详见 [adapters/claude-code.md](adapters/claude-code.md)。其它 agent 仍走通用 `/v1/task/*`;是否为某个 agent 再加这种便捷端点,取决于它是否值得作"一等公民"。

## 编写一个新适配器(如 Codex CLI)

1. 找出该 agent 的"任务开始 / 有进展 / 等待用户 / 任务结束"四类原生信号。
2. 把每类信号映射成对应动词的 HTTP POST,body 填上能拿到的中立字段(至少 `id`)。
3. 用该 agent 自己的 id(session/task id)作 `id`,并带上 `agent` 标签便于展示。
4. 保证调用快速失败、不阻塞 agent。

## 版本

`/v1/` 前缀预留演进空间。未来若增删字段或动词,通过新版本前缀引入,保持 v1 兼容。
