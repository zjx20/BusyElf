# 接入指南:让 Claude Code 驱动 BusyElf

照着做约 2 分钟即可:**有 Claude 在跑长任务时阻止 Mac 休眠,任务结束自动恢复**。

> 本文是"照着做就行"的最短路径。想了解事件映射、设计取舍、`jq` 通用接法,见 [adapters/claude-code.md](adapters/claude-code.md)。

## 前提

- 已装 [Claude Code](https://code.claude.com)。
- BusyElf.app 已构建(见 [BUILD.md](BUILD.md))。**推荐方式 A 零依赖**,不需要 `jq`。

## 第 1 步:启动 BusyElf

双击 BusyElf.app(或 `open BusyElf.app`)。菜单栏出现 ⚡ 图标即就绪。首启会自动选一个可用端口(默认 `127.0.0.1:17872`)并**固定**下来,之后每次启动都用它——所以接入配置写一次就长期有效。

> 想开机自启:点菜单栏图标 → 右键菜单勾「开机启动」。

## 第 2 步:配置 hooks(最省事:让 Claude Code 自己配)

点菜单栏 ⚡ 打开面板 → 右上角 **⋯** → **「接入 agent…」** → 在 `Claude Code` 那行点 **复制提示词**,把它粘进你的 Claude Code 对话即可:它会把 hooks(端口已填好)幂等合并进你的 `~/.claude/settings.json`(先备份、不动你其它 hooks),然后自检 ⚡ 是否点亮。**BusyElf 不会自己改你的任何文件**——是你的 agent 在你眼皮下改。

> 「其他」那一行是给非 Claude Code 的 harness 的通用提示词(中立 `/v1/task/*` 协议),成功率取决于该 harness 的能力。

### 或者:手动配置

把下面这段写进 **`~/.claude/settings.json`**(对所有项目生效)。所有事件全指向同一个 URL,BusyElf 自己分发——**不需要 `jq`、`curl` 或任何脚本**。端口用你 BusyElf 实际监听的那个(右键菜单顶部 / 面板底部有显示;固定后通常就是 17872)。

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PreToolUse":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PostToolUse":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PostToolUseFailure": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "MessageDisplay":   [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Notification":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SubagentStart":    [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SubagentStop":     [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "Stop":             [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "StopFailure":      [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks", "timeout": 5 }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "http", "url": "http://127.0.0.1:17872/claude/hooks" }] }]
  }
}
```

放哪取决于作用范围(三处的 hooks 会**合并**,不是互斥):

| 文件 | 作用范围 |
|---|---|
| `~/.claude/settings.json` | 你的所有项目(最省事,推荐) |
| `<项目>/.claude/settings.json` | 仅该项目,可提交进仓库与团队共享 |
| `<项目>/.claude/settings.local.json` | 仅该项目,个人本地(gitignore) |

> **已有 `hooks` 配置?** 别整段覆盖——把上面这些事件**合并**进你现有的 `"hooks"` 对象即可(同名事件就把这条 handler 追加进它的数组)。

改完设置文件 Claude Code 通常会自动热加载;没生效就重启 Claude Code 会话。用 `/hooks` 可只读查看当前生效的 hooks。

每个事件的作用:

| 事件 | 给你什么 |
|---|---|
| `UserPromptSubmit` / `Stop` / `SessionEnd` | **防休眠核心**:单个长 turn 全程保持 working;`Stop` 让任务变"已完成"(绿色提示,看一次后清理)而非直接消失 |
| `StopFailure` | turn 因 API 错误异常停止 → **红色紧急提示**,展示失败原因(rate_limit 等)与细节;清理前持续 |
| `PreToolUse` | popover **即时**显示"正在做的工具"(工具开始时,不等它做完) |
| `PostToolUse` | 把该工具标为已完成(行内 ✓);并在权限等待结束后把任务从"等待"复活为"工作中" |
| `PostToolUseFailure` | 把该工具标为失败(行内 ✗,hover 看失败原因);工具失败是常态、不代表任务中断,任务仍"工作中" |
| `MessageDisplay` | popover 实时显示 agent 当前回复(话痨:每行助手文本发一发;精简显示,可去掉) |
| `Notification` | 权限等待期间放行休眠并系统提醒 |
| `SubagentStart` / `SubagentStop` | 把 subagent(如 Explore)显示为独立子任务行,挂在父任务下 |

**想更精简**:只留 `UserPromptSubmit` / `Stop` / `SessionEnd` / `StopFailure` 也能用(防休眠 + 完成/失败提示),其余按需加。`PreToolUse` / `PostToolUse` / `MessageDisplay` 是仅有的"话痨"事件,嫌频繁可去掉;但若想要"权限授权后任务自动从等待复活为工作中",至少保留 `PostToolUse`。

## 第 3 步:验证

跑一个真实 Claude 会话:提交 prompt → 菜单栏 ⚡ 点亮 + 计数 +1;`Stop`(答完)→ 计数归零。同时:

```bash
pmset -g assertions | grep BusyElf
# 有 working 任务时出现一条 PreventUserIdleSystemSleep("BusyElf: agents working"),清空后消失
```

不想跑真实会话,也可直接打端点模拟:

```bash
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"UserPromptSubmit","session_id":"t1","cwd":"'"$PWD"'","prompt":"hello"}'   # → 出现一个 working 任务
curl -sS -m2 -X POST http://127.0.0.1:17872/claude/hooks \
  -d '{"hook_event_name":"Stop","session_id":"t1"}'                                                  # → 任务清空
```

## 排错

- **完全没反应**:确认 BusyElf 在跑(菜单栏有 ⚡)、监听在 `17872`。BusyElf 没开时 Claude **不会被卡住**(连接失败是非阻塞错误),只是不记录而已。
- **端口**:首启时若 17872 被占用,BusyElf 会自动往后探测(`17873/17874/17875`,实在没有就让系统随便分配一个),**绑成功后把这个端口固定下来**,之后每次启动都用它——端口稳定,接入配置不会失效。固定后的端口在右键菜单顶部 / 面板底部显示。想手动改:面板「更多设置」里改端口,或 `defaults write elf.busyelf httpPort 12345` 后重开;**改端口后要重新「接入 agent…」复制一次提示词**(URL 变了)。
- **菜单栏图标变红半透明 / 面板顶部红色横幅「端口被占用」**:固定的那个端口这次被别的进程占了,BusyElf 没在接收事件。释放该端口后点横幅 **[重试]**,或点 **[改端口]** 换一个(换完记得重新复制接入指令)。
- **菜单栏有残留任务**:agent 硬崩溃(没发 `Stop`/`SessionEnd`)会残留 working 任务。**看门狗**会在它无活动超过阈值(默认 15 分钟)后标为"可能已断"并**自动放行休眠**;想立刻清掉就点开 popover 用 `×` 移除,或「全部结束」。改阈值:`defaults write elf.busyelf inactivityTimeoutSeconds 900`(下限 60s)后重开。
- **想让其它机器/容器上报任务**:右键菜单勾「监听所有网口 (0.0.0.0)」(首次会弹系统本地网络授权)。注意服务**无鉴权**,仅在可信网络开启。
- **临时全关 hooks**:在设置文件里设 `"disableAllHooks": true`。
- **合盖仍会休眠**:`PreventUserIdleSystemSleep` 只挡"空闲休眠",管不了合盖/手动休眠/低电量。长任务合盖跑请外接显示器 + 电源。

## 接其它 agent(Codex 等)

BusyElf 是 agent 中立的:其它 agent 把自己的"开始/进展/等待/完成/失败/移除"映射到通用协议 `POST /v1/task/{start,update,wait,done,fail,remove}` 即可,无需任何 Claude 专属代码。中立接口与 `/claude/hooks` 表现力对等(子任务、流式回复、失败细节都能用通用字段表达)。见 [PROTOCOL.md](PROTOCOL.md)。

> 面板 ⋯ →「接入 agent…」里的 **「其他」** 那行,复制的就是这套通用协议的现成提示词(端口已填好),可以直接喂给你的 harness 让它照着配。
