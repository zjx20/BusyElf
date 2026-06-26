# 适配器:Claude Code

把 Claude Code 的 hook 事件翻译成 [BusyElf 中立协议](../PROTOCOL.md)。**翻译完全发生在 hook 配置里(`jq` + `curl`),BusyElf 不含任何 Claude 专属逻辑。**

## 事件 → 动词映射

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

**时序天然区分 permission vs idle 通知**(因此不依赖有争议的 `notification_type`):
- `permission_prompt` 在 **turn 进行中**触发 → 任务还在(`working`)→ `wait` 命中 → 标记 waiting + 提醒。
- `idle_prompt`(答完在等下一句)在 **`Stop` 之后**触发 → 任务已被 `end` 移除 → `wait` 找不到任务 → 协议规定**忽略** → 不产生幽灵等待项。

## settings.json

放进 `~/.claude/settings.json`(或项目级 `.claude/settings.json`)。需要本机安装 [`jq`](https://jqlang.github.io/jq/)(`brew install jq`)——它是用户自带的标准工具,**不是 BusyElf ship 的二进制**。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command",
      "command": "jq -c '{id:.session_id, name:.prompt, agent:\"claude-code\"}' | curl -sS -m2 -X POST http://127.0.0.1:17872/v1/task/start --data-binary @- >/dev/null 2>&1 || true" }] }],

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

### 分层(可选精简)

- **只要长循环防休眠**:保留 `UserPromptSubmit` / `Stop` / `SessionEnd` 三条即可(`working` 在单个长 turn 内全程保持)。
- **要"当前工作"展示 + permission 期间放行休眠 + 提醒**:再加 `PostToolUse` 和 `Notification`。
- 注意 `PostToolUse` 是唯一"话痨"的 hook(每次工具调用都发一发 curl)。嫌吵可去掉,代价:popover 只显示任务摘要不逐工具刷新、permission 后恢复要等下一个 turn。

## ⚠️ 字段名需真机确认

多轮 web 核实在**具体字段名上自相矛盾**,典型 LLM 幻觉风险。**上面的 jq 是按最可信猜测写的,但必须用真机 payload 校准**:

| 字段 | 可信度 | 备注 |
|---|---|---|
| `session_id` / `cwd` / `transcript_path` / `hook_event_name` | ✅ 铁实,全事件都有 | |
| `tool_name` / `tool_input`(Pre/PostToolUse) | ✅ 铁实 | Bash 看 `.command`,Edit/Write 看 `.file_path` |
| `tool_response`(PostToolUse) | ✅ 铁实 | 工具结果 |
| `message`(Notification) | ✅ 铁实 | 通知文案 |
| prompt 文本(UserPromptSubmit) | ⚠️ 存疑 | 可能是 `prompt` 或 `prompt_text`,真机确认 |
| `notification_type`(Notification) | ❌ 不可靠 | 多数核实显示实际不下发(#11964);本设计不依赖 |
| `Stop` / `SessionEnd` 的 body 字段 | — | **本适配器不读**,只凭路径 `end` |

**好处**:这些不确定性全被隔离在本适配器的 jq 里。若某 key 名在你的版本不同,**只改这里的 jq,BusyElf 一行不动**。

### 抓真实 payload 锁定字段(P1 做一次)

临时把某个 hook 换成下面这条,触发各事件后看落盘文件,即可读出确切 key:

```json
{ "hooks": { "UserPromptSubmit": [{ "hooks": [{ "type": "command",
  "command": "cat >> ~/busyelf-hook-capture.ndjson" }] }] } }
```

每行自带 `hook_event_name`,把五个事件各配一份、各触发一次,就能确认全部字段名,再回填到上面的 jq。

## 校验

1. 启动 BusyElf。
2. `pmset -g assertions` 应在有 `working` 任务时看到一条 `PreventUserIdleSystemSleep`(name 含 "BusyElf"),任务清空后消失。
3. 跑一个真实 Claude 会话:提交 prompt → 菜单栏计数 +1 且断言出现;turn 结束 → 计数 -1 且断言消失。
