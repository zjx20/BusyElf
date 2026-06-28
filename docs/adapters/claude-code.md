# 适配器:Claude Code

把 Claude Code 的 hook 事件接入 BusyElf。有两种方式:

- **方式 A(推荐,零依赖)**:用 Claude Code 的 **HTTP hook**(`type: "http"`)把每个 hook 的原始 JSON 直接 POST 给 BusyElf 的内建端点 `/claude/hooks`,翻译在 BusyElf 内部完成。**不需要 `jq`、不需要 `curl`、不需要 shell**。
- **方式 B(通用,可移植)**:在 hook 里用 `jq` + `curl` 把字段翻成 [BusyElf 中立协议](../PROTOCOL.md)再 POST 给 `/v1/task/*`。这是"任何 agent 都能照搬"的通用接法,也是理解协议的参考。

> **这破坏中立性吗?不。** `/claude/hooks` 只是把"懂 Claude 字段名"的那点翻译逻辑从 hook 里的 jq 搬进了 BusyElf 内的一个隔离文件([`ClaudeHookEvent.swift`](../../Sources/BusyElf/Server/ClaudeHookEvent.swift)),映射到的仍是同一套中立动词(start/update/wait/done/fail/remove);`TaskStore` / 协议核心永不 import 任何 Claude 概念。Claude Code 因此是 BusyElf 的"一等公民",但其它 agent 仍走通用的 `/v1/task/*`,无需任何 Claude 专属代码。之所以内建,是因为 `jq` 并非人人都装,与其让用户多装一个工具,不如 BusyElf 自己适配——逻辑也不复杂。

## 事件 → 动词映射(两种方式共用同一套语义)

| Claude Code hook | BusyElf 动词 | 语义 |
|---|---|---|
| `UserPromptSubmit` | `start` | 用户提交 prompt → 一个 turn 开始 = 在干活 |
| `SubagentStart` | `start`(子任务) | subagent 生成 → 独立子任务(`agent_id` 折进 id,`parentId`=session,`name`=agent_type) |
| `PreToolUse` | `update`(`toolComplete:false`) | 工具即将执行 → 即时显示"正在做的工具"(不等做完) |
| `PostToolUse` | `update`(`toolComplete:true`) | 工具执行完 → 动作行打 ✓;也是"等待/完成后恢复"的信号 |
| `MessageDisplay` | `update`(reply) | 助手文本流式输出 → 实时回复(`delta`,replace/append) |
| `Notification` | `wait` / 忽略 | 按 `notification_type`:`permission_prompt` → wait;`idle_prompt` 等 → 忽略 |
| `Stop` | `done` | turn 正常结束 = 完成(留存提示,非移除) |
| `SubagentStop` | `done`(子任务) | subagent 完成(`last_assistant_message` 作回复) |
| `StopFailure` | `fail` | turn 因 API 错误异常停止(`error` / `error_details` / 错误原文) |
| `SessionEnd` | `done` | 会话关闭(优雅退出) |

**为什么是这套**:
- 一个长 autonomous loop 通常是"一次 `UserPromptSubmit` → 几小时自主工具调用 → 最后一个 `Stop`"——整段就一个 turn,`working` 从头到尾。`PostToolUse`/`MessageDisplay` 让 popover 实时显示"当前在干什么 / 当前回复"。
- `Stop` 只在 turn **正常结束**时触发 → `done`(任务转"已完成",留存绿点提示,看一次后清理,**不再直接消失**)。turn 因 API 错误结束则走 `StopFailure` → `fail`(红点紧急提示)。
- **中途接管**:BusyElf 若在 agent 干活中途启动会错过 `UserPromptSubmit`;`update`/`wait`/`fail` 都 upsert 创建,所以下一条 `PostToolUse`/`Notification`/`StopFailure` 就能把任务接上,不依赖 start。

**读 `notification_type` 区分 permission vs idle**(原先靠时序区分;现因终态留存、`wait` 改为总是创建,时序不再可靠,故显式读字段——官方已稳定提供):
- `permission_prompt`(turn 进行中需授权)→ `wait` → 标记 waiting + 提醒。
- `idle_prompt`(答完在等下一句)/ 其它类型 → **忽略**,不产生幽灵等待项。

**subagent**:在 subagent 内触发的事件带 `agent_id`(区分主线程 vs 子任务)+ `agent_type`(名字)。BusyElf 把 `agent_id` 折进 task id(`session#agent_id`),`parentId`=session,于是子任务作为独立行挂在父任务下。`SubagentStart`→建子任务,`SubagentStop`→子任务完成。

---

## 方式 A:HTTP hook → `/claude/hooks`(推荐)

放进 `~/.claude/settings.json`(或项目级 `.claude/settings.json`)。**所有事件全部指向同一个 URL**——BusyElf 读 body 里的 `hook_event_name` 自己分发,无需为每个事件配不同路径。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "MessageDisplay":   [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SubagentStart":    [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SubagentStop":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "StopFailure":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks" }] }]
  }
}
```

工作方式:Claude Code 把每个 hook 事件的原始 JSON 作为 POST body 直接发给 BusyElf → BusyElf 内部翻成中立动作落到 TaskStore。

**为什么这不会卡住 Claude**(BusyElf 是纯被动观察者):
- BusyElf 没开 / 端口没人听 → **连接失败,Claude 视为非阻塞错误,正常继续**(无需 `|| true`)。
- BusyElf 在 → 立即回 **2xx + 空 body**(等同退出码 0 无输出),不向 Claude 注入任何上下文、不阻止任何工具、不改任何流程。
- `"timeout": 5` 是个保险绳:这几个事件的 HTTP hook 默认超时较长(`PostToolUse`/`Notification`/`Stop` 为 600s,`UserPromptSubmit` 为 30s),万一 BusyElf 卡住,5s 即放弃(超时同样是非阻塞错误)。BusyElf 事件驱动、微秒级响应,实践中永远碰不到。
- `SessionEnd` **故意不设 `timeout`**:它默认就只有 1.5s,且整体退出预算会自动抬到"配置过的最大 per-hook 超时",写 `timeout:5` 反而把会话退出的最坏等待从 1.5s 放宽到 5s——留默认更利落。

### 分层(可选精简)

- **防休眠 + 完成/失败提示(核心)**:`UserPromptSubmit` / `Stop` / `StopFailure` / `SessionEnd`。
- **"当前工作 / 当前回复"展示**:加 `PreToolUse`(工具开始即显示)、`PostToolUse`(工具做完打 ✓ + 权限授权后复活)和 `MessageDisplay`(实时回复)。
- **permission 期间放行休眠 + 提醒**:加 `Notification`。
- **subagent 独立子任务行**:加 `SubagentStart` / `SubagentStop`。
- 注意 `PreToolUse` / `PostToolUse` / `MessageDisplay` 是仅有的"话痨" hook(每次工具调用前后 / 每行助手文本各发一次)。嫌吵可去掉,代价:popover 不逐工具/逐行刷新;只想保留"授权后复活"则至少留 `PostToolUse`。

### ⚠️ 端口要和 BusyElf 实际监听的一致

URL 里的端口写死成默认 `17872`。**若 17872 被占用,BusyElf 会回退到 17873/17874/17875**,此时上面的 URL 会连到错误的进程或连不上——把端口改成 BusyElf 实际监听的那个(右键菜单顶部显示实际监听地址,或看启动日志 / `lsof -nP -iTCP:17872-17875 -sTCP:LISTEN`)。方式 B 的 curl URL 同理。想固定端口避免回退漂移:`defaults write elf.busyelf httpPort 12345` 后重开 BusyElf,再把所有 hook URL 改成该端口。

---

## 方式 B:jq + curl → `/v1/task/*`(通用/可移植)

需要本机安装 [`jq`](https://jqlang.github.io/jq/)(`brew install jq`)——它是用户自带的标准工具,**不是 BusyElf ship 的二进制**。这条路把翻译留在 hook 里,BusyElf 收到的已是中立 body;任何 agent 都能照此模式接入。

下面用 `id:(.session_id + (if .agent_id then "#"+.agent_id else "" end))` 统一折叠子任务 id;子任务再带 `parentId:.session_id` 与 `name:.agent_type`。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, prompt:.prompt, agent:\"claude-code\", cwd:.cwd}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start --data-binary @- >/dev/null 2>&1 || true" }] }],

    "SubagentStart": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:(.session_id+\"#\"+.agent_id), parentId:.session_id, name:.agent_type, agent:\"claude-code\", cwd:.cwd}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start --data-binary @- >/dev/null 2>&1 || true" }] }],

    "PostToolUse": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:(.session_id+(if .agent_id then \"#\"+.agent_id else \"\" end)), parentId:(if .agent_id then .session_id else null end), name:.agent_type, tool:.tool_name, toolInput:(.tool_input.command // .tool_input.file_path // \"\")}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/update --data-binary @- >/dev/null 2>&1 || true" }] }],

    "MessageDisplay": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, reply:.delta, replyAppend:(.index!=0)}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/update --data-binary @- >/dev/null 2>&1 || true" }] }],

    "Notification": [{ "hooks": [{ "type": "command",
      "command": "jq -c 'select(.notification_type==\"permission_prompt\") | {id:.session_id, message:.message}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/wait --data-binary @- >/dev/null 2>&1 || true" }] }],

    "Stop": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, reply:.last_assistant_message}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/done --data-binary @- >/dev/null 2>&1 || true" }] }],

    "SubagentStop": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:(.session_id+\"#\"+.agent_id), reply:.last_assistant_message}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/done --data-binary @- >/dev/null 2>&1 || true" }] }],

    "StopFailure": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, errorKind:.error, errorDetail:(.error_details // .last_assistant_message)}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/fail --data-binary @- >/dev/null 2>&1 || true" }] }],

    "SessionEnd": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/done --data-binary @- >/dev/null 2>&1 || true" }] }]
  }
}
```

工作方式:Claude 把 hook 的 JSON 从 stdin 喂给命令 → `jq` reshape 成中立 body → `curl` POST 给 BusyElf。`-m2` + `|| true` 保证 BusyElf 没开/卡顿时**不阻塞 Claude**。`Notification` 用 `select(...)` 只在 `permission_prompt` 时才 POST,等价于方式 A 的 `notification_type` 过滤。

> 方式 B 更繁琐(尤其子任务 id 折叠),但能表达和方式 A 完全一样的状态——这正是"中立接口表现力对等"的体现。嫌烦就用方式 A。

---

## Claude hook 字段(已按权威文档锁定)

方式 A 在 [`ClaudeHookEvent.swift`](../../Sources/BusyElf/Server/ClaudeHookEvent.swift) 里读这些字段;方式 B 的 jq 读同样的字段。两者都**best-effort**:任一字段缺失/类型不符只做展示降级,**绝不影响休眠逻辑**(逻辑只看 `hook_event_name` + `session_id`)。

| 字段 | 事件 | 用途 |
|---|---|---|
| `session_id` | 全事件 | → 中立 `id`(任务 key);子任务折成 `session_id#agent_id` |
| `agent_id` | subagent 上下文 | 折进 `id` 区分子任务;并令 `parentId=session_id` |
| `agent_type` | subagent 上下文 | → `name`(子任务标签,如 "Explore") |
| `cwd` | 全事件 | → `cwd`,取 basename 作项目名 |
| `hook_event_name` | 全事件 | 方式 A 据此分发动词 |
| `prompt` | `UserPromptSubmit` | → `prompt`(用户提示词) |
| `tool_name` / `tool_input.*` | `PostToolUse` | → `tool` / `toolInput`(按工具形状取第一个非空) |
| `delta` / `index` | `MessageDisplay` | → `reply`;`index!=0` → `replyAppend=true` |
| `notification_type` / `message` | `Notification` | `permission_prompt` → `wait`;其它忽略 |
| `last_assistant_message` | `Stop` / `SubagentStop` | → `reply`(最终回复,无需解析 transcript) |
| `error` / `error_details` / `last_assistant_message` | `StopFailure` | → `errorKind` / `errorDetail`(失败原因与原文) |

> 历史备注:早期靠状态机时序区分 permission vs idle、刻意不读 `notification_type`。现因终态(done/failed)留存展示、`wait` 改为总是 upsert 创建,时序不再可靠,故**改为显式读 `notification_type`**(官方已稳定提供)。prompt 文本字段确认为 **`prompt`**。

## 校验

1. 启动 BusyElf。
2. `pmset -g assertions` 应在有 `working` 任务时看到一条 `PreventUserIdleSystemSleep`(name 含 "BusyElf"),任务转终态/清空后消失。
3. 跑一个真实 Claude 会话:提交 prompt → 菜单栏计数 +1 且断言出现;turn 结束 → 任务转"已完成"(绿点)、断言消失;若 API 报错异常停止 → "失败"(红点)。

不想跑真实会话也可直接打端点(模拟方式 A):

```bash
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'"$PWD"'","prompt":"hello"}'   # → working
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"Stop","session_id":"t1","last_assistant_message":"done"}'                  # → 已完成(绿点)
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"StopFailure","session_id":"t2","error":"rate_limit"}'                      # → 失败(红点)
```
