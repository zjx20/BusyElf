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

P0–P4 全部模块的源码骨架与构建工程已落地(`project.yml` + `Sources/BusyElf/` 14 个 Swift 文件 + CI),并经多 agent 对抗式评审收敛。**尚未在 macOS 上编译/签名/运行。**

下一步(需在 macOS 上做):
1. `brew install xcodegen && xcodegen generate && xcodebuild -scheme BusyElf build`,修掉真机编译告警。
2. 用 `pmset -g assertions` 验证 0→1 加断言、1→0 释放。
3. 按 [docs/adapters/claude-code.md](docs/adapters/claude-code.md) 抓一遍真实 hook payload,锁定 jq 字段名(`prompt` vs `prompt_text` 等)。
4. 填好 GitHub Secrets,打 tag 触发签名 + 公证发布。

### 工程布局

```
project.yml                 XcodeGen 工程定义(唯一真相源;.xcodeproj 由它生成、gitignore)
ExportOptions.plist         developer-id 导出选项(teamID 由 CI 注入)
Sources/BusyElf/
  App/         BusyElfApp(@main)、AppDelegate(状态栏/popover/server 装配)
  Power/       SleepGuard(IOPMAssertion 引用计数 + 可选显示断言)
  State/       TaskSession(值类型)、TaskStore(幂等状态机 + 串行队列)
  Server/      LoopbackServer(NWListener loopback + 手写 HTTP 解析)、TaskEvent、Router
  UI/          StatusItemController、Notifier、PopoverViewModel、PopoverRootView、AgentRow
  Login/       LoginItem(SMAppService)
.github/workflows/release.yml   tag 触发:archive → 导出签名 → 公证 → Release
```

> ⚠️ 本仓库当前在 Linux dev container 中,**无法编译/运行 macOS 应用**。源码与工程已在此编写,实际 `swift build` / 签名 / 运行需在 macOS 上进行(用 `pmset -g assertions` 验证休眠断言)。
