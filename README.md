# BusyElf 🧝‍⚡

一个极致轻量的原生 macOS 菜单栏常驻应用,配合 AI Agent(如 Claude Code、Codex CLI)工作:**当有 agent 正在跑长任务时阻止系统休眠,任务结束后恢复正常休眠。**

菜单栏图标实时显示正在工作的 agent 数量与状态;agent 需要你处理交互时会提醒你;agent 卡死时可在 UI 里一键移除以解除休眠阻止。

BusyElf 通过一个 **agent 无关的本地 HTTP 协议**接收任务事件——任何 agent 只要写一个适配器把自己的生命周期事件映射到这套协议即可接入,BusyElf 本身不绑定任何特定工具。

## 设计文档

- [docs/DESIGN.md](docs/DESIGN.md) — 架构总览、阻止休眠机制、状态机、资源策略、模块划分、实施阶段、关键决策
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — BusyElf v1 中立任务协议(适配器照此对接)
- [docs/UX.md](docs/UX.md) — 菜单栏图标 / popover / 提醒 / 强制结束的 UI/UX 设计
- [docs/adapters/claude-code.md](docs/adapters/claude-code.md) — Claude Code 适配器(hooks + jq 映射)
- [docs/BUILD.md](docs/BUILD.md) — 纯 CLI 构建与发布(XcodeGen + xcodebuild + GitHub Actions 公证)

## 现状

P0–P4 全部模块已落地,并在 **macOS 26 / Apple Silicon 真机编译、运行、验证通过**:

- **0 warning** 编译(XcodeGen + xcodebuild)。
- 协议→断言状态机逐项正确:`start`/`update` 阻止休眠、`wait` 放行、`update` 恢复、`wait` 忽略不存在 id、`end` 归零;坏输入不崩;进程退出后 powerd 自动回收断言。
- **idle CPU 0%**;**idle phys_footprint ≈ 12MB**(Activity Monitor "内存"口径,达成"数 MB"硬需求)。
- UI **全程纯 AppKit**(含 popover,不链接 SwiftUI)——这正是 12MB 的关键;若 popover 用 SwiftUI,footprint 会被抬到 ~129MB。

待办(真实使用 / 发布):
1. 按 [docs/adapters/claude-code.md](docs/adapters/claude-code.md) 把适配器写进 `~/.claude/settings.json`,先抓一遍真实 hook payload 锁定 jq 字段名(`prompt` vs `prompt_text` 等),跑真实会话端到端。
2. 填好 GitHub Secrets,打 tag 触发 Developer-ID 签名 + 公证发布。

### 工程布局

```
project.yml                 XcodeGen 工程定义(唯一真相源;.xcodeproj 由它生成、gitignore)
ExportOptions.plist         developer-id 导出选项(teamID 由 CI 注入)
Sources/BusyElf/
  App/         BusyElfApp(@main)、AppDelegate(状态栏/popover/server 装配)
  Power/       SleepGuard(IOPMAssertion 引用计数 + 可选显示断言)
  State/       TaskSession(值类型)、TaskStore(幂等状态机 + 串行队列)
  Server/      LoopbackServer(NWListener loopback + 手写 HTTP 解析)、TaskEvent、Router
  UI/          StatusItemController、Notifier、PopoverController、AgentRowView、AppKitHelpers(纯 AppKit)
  Login/       LoginItem(SMAppService)
.github/workflows/release.yml   tag 触发:archive → 导出签名 → 公证 → Release
```

### 本地构建运行

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/BusyElf.app
pmset -g assertions | grep BusyElf     # 有 working 任务时可见休眠断言
```
