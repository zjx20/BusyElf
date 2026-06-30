## 下载哪个?

| 你的 Mac | 下载 |
|---|---|
| **Apple 芯片**(M1/M2/M3/M4…) | `BusyElf-<版本>-arm64.zip` 或 `.dmg` |
| **Intel 芯片** | `BusyElf-<版本>-x86_64.zip` 或 `.dmg` |

> 不确定芯片?点左上角  → 「关于本机」看「芯片 / 处理器」。
> `.zip` 解压后把 `BusyElf.app` 拖进「应用程序」;`.dmg` 双击打开后把图标拖到 Applications 文件夹。

## 首次打开:放行 Gatekeeper(必做一次)

BusyElf **未做 Apple 公证**(那需要 99 美元/年的开发者账号)。它做了 ad-hoc 签名、完全开源,可放心使用——但首次打开 macOS 会拦一下,**放行一次,之后就再也不弹了**。

1. 双击 `BusyElf.app`,弹出「**无法打开"BusyElf",因为 Apple 无法检查其是否包含恶意软件**」→ 点「**完成**」(**别**点「移到废纸篓」)。
2. 打开  →「**系统设置**」→「**隐私与安全性**」,滚到底部「**安全性**」区,会看到一行「已阻止使用"BusyElf"…」,点旁边的「**仍要打开**」。
3. 用 Touch ID / 密码验证,最后一个确认框再点一次「**仍要打开**」。完成 ✅

> ⚠️ macOS Sequoia(15)/ Tahoe(26)起,**右键→打开已不能绕过首次拦截**,必须走上面的「系统设置」。
> 第 2 步的「仍要打开」按钮只在你刚双击被拦后约 1 小时内出现;过期就再双击一次重新触发。

### 嫌麻烦?一条命令搞定(给愿意用终端的人)

```bash
xattr -dr com.apple.quarantine /Applications/BusyElf.app
```

去掉隔离标记后直接双击打开,全程无弹窗。

## 接入 Claude Code / 其它 agent

装好后菜单栏会出现 ⚡。点它打开面板,点右上角的 **⋯** → 选 **「接入 agent…」**,在对应 harness 那行点 **复制提示词**(端口已自动填好,你不用管是多少),把它粘进你的 agent 对话即可——agent 会读懂提示词、自己把 hooks 幂等合并进配置文件(对 Claude Code 是 `~/.claude/settings.json`,会先备份、不动你已有的配置)。配好后让 agent 随便跑个长任务,⚡ 应当点亮、计数 +1,任务结束自动归零并放行休眠。

> 整个过程 BusyElf 不碰你的任何文件,是你自己的 agent 在你眼皮底下完成配置。不想用接入向导,也可照 [docs/SETUP.md](https://github.com/zjx20/BusyElf/blob/main/docs/SETUP.md) 手动把 hooks 写进配置文件,效果一样。
