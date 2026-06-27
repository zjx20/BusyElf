# 适配器:Claude Code

把 Claude Code 的 hook 事件接入 BusyElf。有两种方式:

- **方式 A(推荐,零依赖)**:用 Claude Code 的 **HTTP hook**(`type: "http"`)把每个 hook 的原始 JSON 直接 POST 给 BusyElf 的内建端点 `/claude/hooks`,翻译在 BusyElf 内部完成。**不需要 `jq`、不需要 `curl`、不需要 shell**。
- **方式 B(通用,可移植)**:在 hook 里用 `jq` + `curl` 把字段翻成 [BusyElf 中立协议](../PROTOCOL.md)再 POST 给 `/v1/task/*`。这是"任何 agent 都能照搬"的通用接法,也是理解协议的参考。

> **这破坏中立性吗?不。** `/claude/hooks` 只是把"懂 Claude 字段名"的那点翻译逻辑从 hook 里的 jq 搬进了 BusyElf 内的一个隔离文件([`ClaudeHookEvent.swift`](../../Sources/BusyElf/Server/ClaudeHookEvent.swift)),映射到的仍是同一套中立的 4 动词;`TaskStore` / 协议核心永不 import 任何 Claude 概念。Claude Code 因此是 BusyElf 的"一等公民",但其它 agent 仍走通用的 `/v1/task/*`,无需任何 Claude 专属代码。之所以内建,是因为 `jq` 并非人人都装,与其让用户多装一个工具,不如 BusyElf 自己适配——逻辑也不复杂。

## 事件 → 动词映射(两种方式共用同一套语义)

| Claude Code hook | BusyElf 动词 | 语义 |
|---|---|---|
| `UserPromptSubmit` | `start` | 用户提交 prompt → 一个 turn 开始 = 在干活 |
| `PostToolUse` | `update` | 工具执行完 → 在干活;也是"等待用户后恢复"的信号 |
| `Notification` | `wait` | 需要用户处理(权限请求 / 追问) |
| `Stop` | `end` | turn 结束 = 在等用户 = idle |
| `SessionEnd` | `end` | 会话关闭(优雅退出) |

**为什么是这套**:
- 一个长 autonomous loop 通常是"一次 `UserPromptSubmit` → 几小时自主工具调用 → 最后一个 `Stop`"——整段就一个 turn,`working` 从头到尾,根本不触发 permission。所以 `Notification`/`PostToolUse` 只在**开着交互式授权**时才有意义。
- `Stop` 只在 turn **正常结束**时触发,不会在 turn 进行中(等权限时)触发——所以等权限期间任务不会被 `end`。
- permission 流程:`UserPromptSubmit`(turn 开始)→ … → 需授权(turn 未结束)→ 你批准 → 工具执行 → `PostToolUse` → … → `Stop`(turn 真正结束)。**批准没有专属 hook,`PostToolUse` 就是恢复信号**(`UserPromptSubmit` 只在新 prompt 时触发,批准不算)。

**时序天然区分 permission vs idle 通知**(因此刻意不读 `notification_type`——官方虽列了该字段,但靠时序更稳,字段缺失/语义变也不受影响):
- `permission_prompt` 在 **turn 进行中**触发 → 任务还在(`working`)→ `wait` 命中 → 标记 waiting + 提醒。
- `idle_prompt`(答完在等下一句)在 **`Stop` 之后**触发 → 任务已被 `end` 移除 → `wait` 找不到任务 → 协议规定**忽略** → 不产生幽灵等待项。

---

## 方式 A:HTTP hook → `/claude/hooks`(推荐)

放进 `~/.claude/settings.json`(或项目级 `.claude/settings.json`)。**五个事件全部指向同一个 URL**——BusyElf 读 body 里的 `hook_event_name` 自己分发,无需为每个事件配不同路径。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
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

- **只要长循环防休眠**:保留 `UserPromptSubmit` / `Stop` / `SessionEnd` 三条即可(`working` 在单个长 turn 内全程保持)。
- **要"当前工作"展示 + permission 期间放行休眠 + 提醒**:再加 `PostToolUse` 和 `Notification`。
- 注意 `PostToolUse` 是唯一"话痨"的 hook(每次工具调用都发一次)。嫌吵可去掉,代价:popover 只显示任务摘要不逐工具刷新、permission 后恢复要等下一个 turn。

### ⚠️ 端口要和 BusyElf 实际监听的一致

URL 里的端口写死成默认 `17872`。**若 17872 被占用,BusyElf 会回退到 17873/17874/17875**,此时上面的 URL 会连到错误的进程或连不上——把端口改成 BusyElf 实际监听的那个(见 BusyElf 启动日志,或 `lsof -nP -iTCP:17872-17875 -sTCP:LISTEN`)。方式 B 的 curl URL 同理。

---

## 方式 B:jq + curl → `/v1/task/*`(通用/可移植)

需要本机安装 [`jq`](https://jqlang.github.io/jq/)(`brew install jq`)——它是用户自带的标准工具,**不是 BusyElf ship 的二进制**。这条路把翻译留在 hook 里,BusyElf 收到的已是中立 body;任何 agent 都能照此模式接入。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, name:.prompt, agent:\"claude-code\", cwd:.cwd}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start --data-binary @- >/dev/null 2>&1 || true" }] }],

    "PostToolUse": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, tool:.tool_name, detail:(.tool_input.command // .tool_input.file_path // \"\")}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/update --data-binary @- >/dev/null 2>&1 || true" }] }],

    "Notification": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, message:.message}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/wait --data-binary @- >/dev/null 2>&1 || true" }] }],

    "Stop": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/end --data-binary @- >/dev/null 2>&1 || true" }] }],

    "SessionEnd": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/end --data-binary @- >/dev/null 2>&1 || true" }] }]
  }
}
```

工作方式:Claude 把 hook 的 JSON 从 stdin 喂给命令 → `jq` reshape 成中立 body → `curl` POST 给 BusyElf。`-m2` + `|| true` 保证 BusyElf 没开/卡顿时**不阻塞 Claude**。

---

## Claude hook 字段(已按权威文档锁定)

方式 A 在 [`ClaudeHookEvent.swift`](../../Sources/BusyElf/Server/ClaudeHookEvent.swift) 里读这些字段;方式 B 的 jq 读同样的字段。两者都**best-effort**:任一字段缺失/类型不符只做展示降级,**绝不影响休眠逻辑**(逻辑只看 `hook_event_name` + `session_id`)。

| 字段 | 事件 | 用途 |
|---|---|---|
| `session_id` | 全事件 | → 中立 `id`(任务 key) |
| `cwd` | 全事件 | → `cwd`,取 basename 作项目名 |
| `hook_event_name` | 全事件 | 方式 A 据此分发动词 |
| `prompt` | `UserPromptSubmit` | → `name`(任务名/prompt 文本) |
| `tool_name` | `PostToolUse` | → `tool` |
| `tool_input.command` / `.file_path` / `.path` / `.pattern` / `.url` / `.notebook_path` | `PostToolUse` | → `detail`(按工具形状取第一个非空) |
| `message` | `Notification` | → 等待文案 |
| `reason` | `SessionEnd` | 不读(只凭事件名 `end`) |

> 历史备注:早期对 `prompt` vs `prompt_text`、`notification_type` 是否下发等有不确定。现已对照官方 hooks 参考确认:prompt 文本字段就是 **`prompt`**;本设计**不依赖** `notification_type`(靠状态机时序区分 permission vs idle)。

## 校验

1. 启动 BusyElf。
2. `pmset -g assertions` 应在有 `working` 任务时看到一条 `PreventUserIdleSystemSleep`(name 含 "BusyElf"),任务清空后消失。
3. 跑一个真实 Claude 会话:提交 prompt → 菜单栏计数 +1 且断言出现;turn 结束 → 计数 -1 且断言消失。

不想跑真实会话也可直接打端点(模拟方式 A):

```bash
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'"$PWD"'","prompt":"hello"}'   # → working
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"Stop","session_id":"t1"}'                                                  # → 移除
```
