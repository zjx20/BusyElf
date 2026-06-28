# BusyElf 🧝‍⚡

> **English Version:** [README.en.md](README.en.md)

> AI agent 在跑长任务时,让你的 Mac 别睡;并在菜单栏给你一个统一面板,一眼看清每个 agent 在干嘛。

一个极致轻量的原生 macOS 菜单栏常驻应用。配合 Claude Code 这类 AI agent 使用——**只在真的有 agent 在干活时阻止系统休眠,任务一结束立刻恢复**;同时把你所有正在跑的 agent 收进一个面板,谁在工作、谁等你确认、谁完成了、谁失败了,一目了然。

## 为什么需要它

你让 Claude Code 跑一个十几分钟的重构,然后去倒杯咖啡。回来发现 Mac 睡着了,任务卡在半路、网络断了——因为你没碰键鼠,系统以为你离开了。

常见的"对策"有两种,都不好:

- **手动防睡工具**(caffeine 之类):一开就让 Mac 永远不睡,哪怕 agent 早就跑完了,纯粹浪费电、压根记不住要关。
- **时不时去晃一下鼠标**:得一直惦记着,失去了让 agent 自己跑的意义。

BusyElf 把这件事做对:**有 agent 正在工作才阻止休眠,工作一结束马上放行**,全程不用你管。

而且当你同时开着好几个 agent / 终端时,很容易乱——哪个还在跑?哪个停下来等你点"允许"?哪个已经完成了?BusyElf 在菜单栏给你**一个统一面板**:

- **菜单栏图标**实时反映状态:在干活 / 等你确认 / 完成 / 失败,以及正在工作的数量。
- **popover 列表**逐个列出每个任务,正在执行的工具、最新回复、子任务都看得到。
- **需要你介入时主动提醒**(比如 agent 在等权限确认),完成 / 失败也有提示。
- agent 卡死了,可以在面板里**一键移除**来解除休眠阻止。

## 它怎么知道 agent 在干嘛:hooks

BusyElf 不监控进程、不读你的项目文件,而是**被动接收 agent 主动上报的事件**。Claude Code 这类工具支持 [hooks](https://docs.claude.com/en/docs/claude-code/hooks)——在"开始一个 turn""调用工具""停下来等你""结束"等时机回调一个 URL。BusyElf 在本机监听一个端口(默认 `127.0.0.1:17872`),接住这些事件,据此判断该不该阻止休眠、面板里该显示什么。

接入是**纯加法**:BusyElf 只观察,绝不向 agent 注入内容、不阻止任何工具、不改它的流程。没开 BusyElf 时,agent 照常工作,只是没人记录而已。

## 安装与接入(三步)

### 1. 下载并运行

去 [Releases 页面](https://github.com/zjx20/BusyElf/releases) 下载对应你 Mac 芯片的版本:

| 你的 Mac | 下载 |
|---|---|
| **Apple 芯片**(M1/M2/M3/M4…) | `BusyElf-<版本>-arm64.zip` 或 `.dmg` |
| **Intel 芯片** | `BusyElf-<版本>-x86_64.zip` 或 `.dmg` |

> 不确定芯片?点左上角  → 「关于本机」看「芯片 / 处理器」。

解压(或挂载 dmg)后把 `BusyElf.app` 拖进「应用程序」,双击打开。菜单栏出现 ⚡ 图标就说明跑起来了。

> **首次打开会被 macOS 拦一下。** BusyElf 是开源、ad-hoc 签名但未做 Apple 公证(公证需要付费开发者账号)。放行一次、之后永不再弹:打开「**系统设置 → 隐私与安全性**」,滚到底部「安全性」区,点「**仍要打开**」并验证即可。详细步骤(含一条命令的快捷做法)见 [Release 说明](.github/RELEASE_BODY.md)。
>
> ⚠️ macOS Sequoia(15)/ Tahoe(26)起,右键→打开**已不能**绕过首次拦截,必须走上面的「系统设置」。

### 2. 打开接入界面

点菜单栏 ⚡ 打开面板,点右上角的 **⋯** 按钮 → 选 **「接入 agent…」**。会弹出一个窗口,里面每个支持的 harness 一行,各带一个 **复制提示词** 按钮。提示词里已经**自动填好了 BusyElf 当前监听的端口**,你不用关心端口是多少。

### 3. 把提示词发给你的 agent

在对应那行点 **复制提示词**,然后把它**粘进你的 agent 对话**(比如直接发给 Claude Code)。agent 会读懂这段提示词,自己把 hooks 幂等地合并进它的配置文件(对 Claude Code 是 `~/.claude/settings.json`)——会先备份、不动你已有的其它 hooks——然后自检 ⚡ 是否点亮。

整个过程 **BusyElf 不碰你的任何文件**,是你自己的 agent 在你眼皮底下完成配置。配好后下次启动 BusyElf 会复用同一个端口,配置写一次就长期有效。

> 想验证是否生效:让 agent 随便跑个任务,菜单栏 ⚡ 应当点亮、计数 +1;任务结束后归零。手动核对可跑 `pmset -g assertions | grep BusyElf`,有任务在跑时能看到一条 `PreventUserIdleSystemSleep`。
>
> 不想用接入向导,也可以照 [docs/SETUP.md](docs/SETUP.md) 手动把 hooks 写进配置文件,效果一样。

## 支持哪些 agent(harness)

| Harness | 支持程度 |
|---|---|
| **Claude Code** | ✅ 原生支持。内建 `/claude/hooks` 端点直接吃 Claude Code 的 hook 事件,零依赖、零脚本。 |
| 其它(Codex 等) | ⚙️ 通用协议。BusyElf 的核心是 **agent 无关**的,任何 harness 只要把"开始/进展/等待/完成/失败"映射到通用的 `POST /v1/task/*` 协议即可接入。接入向导里的「其他」那行,复制的就是这套通用协议的现成提示词,可直接喂给你的 harness 让它照着配;成功率取决于该 harness 自身的能力。详见 [docs/PROTOCOL.md](docs/PROTOCOL.md)。 |

目前**只有 Claude Code 是原生开箱支持**的。欢迎为更多 harness 贡献适配。

## 为什么这么轻

BusyElf 常驻后台,所以它必须几乎不占资源:

- **idle 时 CPU 0%**:完全事件驱动,没有轮询、没有常驻定时器。
- **内存约 12MB**:UI 全程**纯手写 AppKit**,刻意不链接 SwiftUI(用 SwiftUI 会把内存抬到约 129MB)。
- 进程退出后,系统会自动回收它持有的休眠阻止断言——不会因为 app 崩了就让 Mac 永远不睡。

> **休眠正确性是第一优先级。** "阻止休眠"的判据是"是否存在任一正在工作、且最近还有活动的任务",用集合成员判定而非计数,事件丢失/乱序也不会漂移。agent 硬崩溃没发结束事件时,**看门狗**会在它无活动超过阈值(默认 15 分钟)后自动放行休眠。

> ℹ️ `PreventUserIdleSystemSleep` 只挡"空闲休眠",管不了合盖 / 手动休眠 / 低电量。长任务合盖跑请外接显示器 + 接电源。

## 文档

- [docs/SETUP.md](docs/SETUP.md) — **接入指南**:2 分钟把 Claude Code 接到 BusyElf(含手动配置与排错)
- [docs/DESIGN.md](docs/DESIGN.md) — 架构总览、阻止休眠机制、状态机、资源策略、模块划分、关键决策
- [docs/PROTOCOL.md](docs/PROTOCOL.md) — BusyElf v1 中立任务协议(给其它 agent 的适配器照此对接)
- [docs/UX.md](docs/UX.md) — 菜单栏图标 / popover / 提醒 / 强制结束的 UI/UX 设计
- [docs/adapters/claude-code.md](docs/adapters/claude-code.md) — Claude Code 适配器细节(内建 `/claude/hooks` 或通用 jq+curl)
- [docs/BUILD.md](docs/BUILD.md) — 纯 CLI 构建与发布(XcodeGen + xcodebuild + GitHub Actions 双架构打包)

## 开发与构建

需要 [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)。工程定义在 `project.yml`,`.xcodeproj` 由它生成(gitignore,从不手改)。

```bash
# 一键拉起(最常用):构建 → 关掉旧实例 → 后台启动,菜单栏出现 ⚡
scripts/run.sh           # --build 强制重建 / --debug 开调试端点 / --stop 仅停

# 或手动构建运行
xcodegen generate
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Release/BusyElf.app
pmset -g assertions | grep BusyElf     # 有任务在跑时可见休眠断言

# 测试
scripts/test-unit.sh        # 白盒单元测试(状态机 / 适配器映射 / 解析)
scripts/test-busyelf.sh     # 端到端:自启实例 → 打真实端点 → 断言内部状态
```

工程结构、扩展点、调试教训等给贡献者看的细节,见 [CLAUDE.md](CLAUDE.md)。
