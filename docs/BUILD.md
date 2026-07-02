# 构建与发布(纯 CLI,不开 Xcode 窗口)

路线:**XcodeGen + xcodebuild**。仓库只放人类可读的 `project.yml`;`.xcodeproj` 由 `xcodegen` 生成(gitignore,从不手改、从不打开)。构建/签名/公证全部命令行,适配 GitHub Actions。

> Xcode 只提供工具链。永远不打开 Xcode.app。用到的 CLI:`xcodegen`、`xcodebuild`、`xcrun`、`codesign`、`notarytool`、`stapler`、`swift`。

## 前置

- macOS + **完整 Xcode**(非仅 Command Line Tools;`xcodebuild` 构建 app target 需要它)。GitHub `macos-14` runner 已预装。
- `brew install xcodegen`
- (调试 Claude 适配器用)`brew install jq`

## 仓库布局

```
BusyElf/
  project.yml                     # XcodeGen 工程定义(唯一工程真相源)
  ExportOptions.plist             # xcodebuild 导出选项(developer-id)
  Sources/BusyElf/                # 所有 .swift(见 DESIGN.md §10 模块划分)
  Resources/                      # AppIcon.icns 等
  .github/workflows/release.yml
  BusyElf.xcodeproj/              # ← xcodegen 生成, gitignore
```

## project.yml(可直接用)

```yaml
name: BusyElf
options:
  bundleIdPrefix: elf
  deploymentTarget: { macOS: "14.0" }
  createIntermediateGroups: true
settings:
  base:
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "5.10"
    PRODUCT_BUNDLE_IDENTIFIER: elf.busyelf
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "Developer ID Application"
    ENABLE_HARDENED_RUNTIME: YES          # 公证必需
    DEVELOPMENT_TEAM: ${DEVELOPMENT_TEAM} # CI 从环境注入(本地可留空跑 Debug 不签名)
targets:
  BusyElf:
    type: application
    platform: macOS
    sources:
      - Sources/BusyElf
      - path: Resources               # XcodeGen 无 resources 键;靠 sources 按扩展名把 AppIcon.icns 分流到 Resources 阶段
        excludes: ["README.md"]
    # XcodeGen 直接由这些属性生成 Info.plist,无需单独 Info.plist 文件
    info:
      path: BusyElf-Info.plist
      properties:
        LSUIElement: true                 # 菜单栏 app,无 Dock 图标
        CFBundleName: BusyElf
        CFBundleIconFile: AppIcon          # Resources/AppIcon.icns(源 design/AppIcon.svg)
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        LSMinimumSystemVersion: "14.0"
    entitlements:
      path: BusyElf.entitlements
      properties:
        com.apple.security.app-sandbox: false   # 非沙盒, Developer ID 外分发
```

非沙盒 + hardened runtime 即可满足 `IOPMAssertion` / `SMAppService` / `UNUserNotificationCenter`,无需额外 entitlement。

## 本地命令

```bash
xcodegen generate                                   # 生成 .xcodeproj
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/.../BusyElf.app   # 或用 -derivedDataPath 固定输出
pmset -g assertions                                 # 验证休眠断言(P0 核心)
```

## 测试

两层,均可 CLI 一行跑:

```bash
scripts/test-unit.sh      # 白盒单元测试(XCTest):TaskStore 状态机 / ClaudeHookEvent 映射 / TaskEvent 解析
scripts/test-busyelf.sh   # 端到端(E2E):自启实例 → 打真实 HTTP 端点 → 断言内部状态。覆盖 7 大需求
```

- **单元测试**(`Tests/`,target `BusyElfTests`):宿主测试;`AppDelegate` 在 XCTest 下跳过 app 装配,只跑纯逻辑。`TaskStore` 的同步测试辅助(`snapshotSync`/`resetSync`)用 `#if DEBUG` 包裹,**不进 Release**。
- **E2E**(`scripts/test-busyelf.sh`):依赖 `jq`。靠一个**调试观测接口**做断言,无需 sleep:
  - 仅当以 `BUSYELF_DEBUG=1` 启动时开启 `/debug/*`(生产默认关闭,不暴露内部状态):
    - `GET /debug/state` → 全部任务的内部状态 JSON + 派生量(`blocking`/`hasUnseenDone`/`hasFailed`)。读用 `queue.sync`,兼作**写后读屏障**,故断言不用等。
    - `POST /debug/reset`(清空)、`/debug/seen`(模拟打开 popover)、`/debug/purge`(模拟关闭)——让 seen 生命周期也能无头测试。
  - 脚本会探测自己启动的实例端口,不会踩用户已开的正常实例。

## ExportOptions.plist

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>YOUR_TEAM_ID</string>
</dict></plist>
```

## 发布(GitHub Actions,免开发者账号)

当前 `.github/workflows/release.yml` 走**免 Apple 开发者账号**路线:**ad-hoc 签名**(`codesign -s -`),不公证。打 tag 即出 **Intel(x86_64)+ Apple Silicon(arm64)各一份 zip 和 dmg**,挂到 GitHub Release。

```bash
# 前提:仓库已推到 GitHub。打 tag 触发:
git tag v0.1.0
git push origin v0.1.0
```

也可在 Actions 页 **Run workflow** 手动触发:填 `version`(如 `v0.1.0`)就发版;**留空只构建+上传产物、不建 Release**(用来试跑构建)。

**流水线结构**(fan-out / fan-in,见 `release.yml`):

1. `build` 矩阵 `[arm64, x86_64]` 跑在 `macos-15`(arm64 runner,单机交叉编译出 x86_64)。每条腿调 `scripts/ci-package.sh`,产出 `dist/*`,以**唯一名** `dist-<arch>` 上传 artifact(`upload-artifact@v4` 禁止同名)。
2. `release` job `needs: build`,`download-artifact ... merge-multiple: true` 合并所有产物,**一次** `softprops/action-gh-release@v2` 建 Release 挂全部资产——避免每条腿各自发版的并发竞争。
3. 仅 tag 触发或手动填了 `version` 时才发版(`if:` 守卫)。

**打包逻辑全在 `scripts/ci-package.sh`**(本地可完整复现 CI 的一条腿):

```bash
ARCH=arm64  REF_NAME=v0.1.0 scripts/ci-package.sh   # 原生
ARCH=x86_64 REF_NAME=v0.1.0 scripts/ci-package.sh   # 交叉编译
```

它做四件事:① `xcodebuild` ad-hoc 构建单 arch(`ARCHS=<arch> ONLY_ACTIVE_ARCH=NO`,关键交叉编译开关;覆盖工程默认的 Developer ID;`ENABLE_HARDENED_RUNTIME=NO`;`MARKETING_VERSION` 由 tag 注入)→ ② `codesign --force --deep -s -` 干净重签(xcodebuild 出的是 linker-signed,会有 verify 告警)→ ③ `lipo -archs` 断言架构 → ④ `ditto` 出 zip、`hdiutil`(无 Finder/AppleScript)出拖拽式 dmg 到 `dist/`。

**用户侧装机**:ad-hoc 签名**不能去掉** Gatekeeper 首拦,但比不签名好(把死路「已损坏」变成可绕过的「Apple 无法检查」)。用户首次打开走「系统设置 → 隐私与安全性 → 仍要打开」一次即可;说明写在 `.github/RELEASE_BODY.md`(会自动置于 Release 自动更新日志之前)。**Sequoia 15 / Tahoe 26 起右键→打开已失效**,必须走系统设置;或一条命令 `xattr -dr com.apple.quarantine /Applications/BusyElf.app`。

> 关键事实(已在本机实测 + 查证 2026 中):runner 用 `macos-15`(`macos-latest` 正 15→26 迁移会飘,`macos-14` 将弃用、`macos-13` 已下线);一个 arm64 runner 即可交叉出 x86_64;`create-dmg` 在无头 CI 因 AppleScript 不可靠,故用 `hdiutil`;DMG 用 `-fs HFS+` 最大兼容。

## 升级路径:Developer ID 签名 + 公证(有付费账号后)

有了 99 美元/年的 Apple Developer Program 后,可让用户**下载即开、无任何弹窗**:把 `project.yml` 的 `ENABLE_HARDENED_RUNTIME` 保持 `YES`(公证必需),CI 改为 archive → 用 Developer ID 导出 → `notarytool submit --wait` 公证 → `stapler staple` 钉票 → 出 zip/dmg。参考流水线(替换上面的 ad-hoc 流程):

```yaml
# 关键步骤(完整版见 git 历史里的旧 release.yml):
- uses: apple-actions/import-codesign-certs@v3            # 导入 Developer ID .p12
  with: { p12-file-base64: ${{ secrets.DEV_ID_P12 }}, p12-password: ${{ secrets.DEV_ID_P12_PASSWORD }} }
- run: |
    xcodegen generate
    xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
      -archivePath build/BusyElf.xcarchive archive
    /usr/libexec/PlistBuddy -c "Set :teamID ${{ secrets.APPLE_TEAM_ID }}" ExportOptions.plist
    xcodebuild -exportArchive -archivePath build/BusyElf.xcarchive \
      -exportOptionsPlist ExportOptions.plist -exportPath build/export
    cd build/export && ditto -c -k --keepParent BusyElf.app BusyElf.zip
    echo "${{ secrets.ASC_API_KEY_P8 }}" | base64 -d > AuthKey.p8
    xcrun notarytool submit BusyElf.zip --key AuthKey.p8 \
      --key-id "${{ secrets.ASC_KEY_ID }}" --issuer "${{ secrets.ASC_ISSUER_ID }}" --wait
    xcrun stapler staple BusyElf.app
```

需要的 Secrets:

| Secret | 来源 |
|---|---|
| `DEV_ID_P12` | `Developer ID Application` 证书导出的 `.p12`,`base64 -i cert.p12 \| pbcopy` |
| `DEV_ID_P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `APPLE_TEAM_ID` | 开发者账号 Team ID(10 位) |
| `ASC_API_KEY_P8` | App Store Connect API key `.p8` 的 base64(用于公证) |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` | 该 API key 的 Key ID / Issuer ID |

## 应用图标

唯一真相源是 `design/AppIcon.svg`;改它后跑 `scripts/make-icon.sh` 重生成 `Resources/AppIcon.icns`(icns 入库,这样 CI/构建不依赖光栅化器)。`project.yml` 经 `CFBundleIconFile: AppIcon` 引用它,且 `Resources` 必须挂在 **`sources`** 下(XcodeGen 没有 `resources:` 键,按扩展名把 `.icns` 自动分流到 Resources 构建阶段)。

## 备注

- 想要自动更新可后续接 **Sparkle**(同样全 CLI:生成 appcast、签名 update)。
- 本地快速迭代也可保留一份 `Package.swift` 用 `swift build` 跑逻辑,但工程/签名以 XcodeGen+xcodebuild 为准,避免双源维护。
