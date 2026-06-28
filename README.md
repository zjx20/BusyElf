# BusyElf 🧝‍⚡

一个极致轻量的原生 macOS 菜单栏常驻应用,配合 AI Agent(如 Claude Code、Codex CLI)工作:**当有 agent 正在跑长任务时阻止系统休眠,任务结束后恢复正常休眠。**

菜单栏图标实时显示正在工作的 agent 数量与状态;agent 需要你处理交互时会提醒你;agent 卡死时可在 UI 里一键移除以解除休眠阻止。

BusyElf 通过一个 **agent 无关的本地 HTTP 协议**接收任务事件——任何 agent 只要写一个适配器把自己的生命周期事件映射到这套协议即可接入,BusyElf 本身不绑定任何特定工具。

## 文档

- [docs/SETUP.md](docs/SETUP.md) — **接入指南**:2 分钟把 Claude Code 接到 BusyElf(照着做就行)
- [docs/DESIGN.md](docs/DESIGN.md) — 架构总览、阻止休眠机制、状态机、资源策略、模块划分、实施阶段、关键决策
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — BusyElf v1 中立任务协议(适配器照此对接)
- [docs/UX.md](docs/UX.md) — 菜单栏图标 / popover / 提醒 / 强制结束的 UI/UX 设计
- [docs/adapters/claude-code.md](docs/adapters/claude-code.md) — Claude Code 适配器(推荐内建 `/claude/hooks`,零依赖;或通用 jq+curl)
- [docs/BUILD.md](docs/BUILD.md) — 纯 CLI 构建与发布(XcodeGen + xcodebuild + GitHub Actions 公证)

## 现状

P0–P4 全部模块已落地,并在 **macOS 26 / Apple Silicon 真机编译、运行、验证通过**:

- **0 warning** 编译(XcodeGen + xcodebuild)。
- 协议→断言状态机逐项正确:`start`/`update` 阻止休眠、`wait` 放行、`update` 复活、`done`/`fail` 转终态放行、`remove` 归零;中途启动靠 upsert 接管;坏输入不崩;进程退出后 powerd 自动回收断言。
- **idle CPU 0%**;**idle phys_footprint ≈ 12MB**(Activity Monitor "内存"口径,达成"数 MB"硬需求)。
- UI **全程纯 AppKit**(含 popover,不链接 SwiftUI)——这正是 12MB 的关键;若 popover 用 SwiftUI,footprint 会被抬到 ~129MB。

待办(真实使用 / 发布):
1. 按 [docs/SETUP.md](docs/SETUP.md) 把 hooks 写进 `~/.claude/settings.json`(推荐内建 `/claude/hooks` HTTP hook,零依赖),跑真实 Claude 会话端到端验证计数与断言翻转。
2. 把仓库推到 GitHub,打 tag `vX.Y.Z` 触发发布(免开发者账号:ad-hoc 签名,出 Intel + Apple Silicon 各一份 zip/dmg)。装机与 Gatekeeper 放行见 [docs/BUILD.md](docs/BUILD.md) / Release 说明。

### 工程布局

```
project.yml                 XcodeGen 工程定义(唯一真相源;.xcodeproj 由它生成、gitignore)
ExportOptions.plist         developer-id 导出选项(仅"签名+公证"升级路径用,见 BUILD.md)
design/AppIcon.svg          应用图标源(改后跑 scripts/make-icon.sh 重生成 icns)
Resources/AppIcon.icns      应用图标(入库;经 CFBundleIconFile 引用)
Sources/BusyElf/
  App/         BusyElfApp(@main)、AppDelegate(状态栏/popover/server 装配)
  Power/       SleepGuard(IOPMAssertion 引用计数 + 可选显示断言)
  State/       TaskSession(值类型)、TaskStore(幂等状态机 + 串行队列)
  Server/      LoopbackServer(NWListener loopback + 手写 HTTP 解析)、Router(路径分流)、TaskEvent(中立)、ClaudeHookEvent(内建 Claude 适配)
  UI/          StatusItemController、Notifier、PopoverController、AgentRowView、AppKitHelpers(纯 AppKit)
  Login/       LoginItem(SMAppService)
Tests/                      白盒单元测试(XCTest;target BusyElfTests):状态机 / 适配器 / 解析
scripts/
  test-unit.sh              一行跑单元测试
  test-busyelf.sh           一行跑端到端(自启实例 + /debug/state 断言,覆盖 7 大需求)
  ci-package.sh             单架构 ad-hoc 构建+签名+打包(zip+dmg);CI 与本地复现共用
  make-icon.sh              design/AppIcon.svg → Resources/AppIcon.icns
.github/
  workflows/release.yml     tag 触发:矩阵构建 arm64+x86_64 → ad-hoc 签名 → zip/dmg → Release
  RELEASE_BODY.md           Release 正文(装机 + Gatekeeper 放行说明)
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
