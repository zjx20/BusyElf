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
    sources: [Sources/BusyElf]
    resources: [Resources]
    # XcodeGen 直接由这些属性生成 Info.plist,无需单独 Info.plist 文件
    info:
      path: BusyElf-Info.plist
      properties:
        LSUIElement: true                 # 菜单栏 app,无 Dock 图标
        CFBundleName: BusyElf
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

## GitHub Actions:.github/workflows/release.yml

```yaml
name: Release
on:
  push: { tags: ["v*"] }
jobs:
  release:
    runs-on: macos-14
    env:
      DEVELOPMENT_TEAM: ${{ secrets.APPLE_TEAM_ID }}
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: "16" }
      - run: brew install xcodegen

      # 1) 导入 Developer ID 证书到临时 keychain
      - uses: apple-actions/import-codesign-certs@v3
        with:
          p12-file-base64: ${{ secrets.DEV_ID_P12 }}
          p12-password:    ${{ secrets.DEV_ID_P12_PASSWORD }}

      # 2) 生成工程 + archive + 导出已签名 .app
      - run: |
          xcodegen generate
          xcodebuild -project BusyElf.xcodeproj -scheme BusyElf \
            -configuration Release -archivePath build/BusyElf.xcarchive archive
          xcodebuild -exportArchive -archivePath build/BusyElf.xcarchive \
            -exportOptionsPlist ExportOptions.plist -exportPath build/export

      # 3) 公证(App Store Connect API key,比 apple-id+专用密码更稳)
      - run: |
          cd build/export
          ditto -c -k --keepParent BusyElf.app BusyElf.zip
          echo "${{ secrets.ASC_API_KEY_P8 }}" | base64 -d > AuthKey.p8
          xcrun notarytool submit BusyElf.zip \
            --key AuthKey.p8 \
            --key-id "${{ secrets.ASC_KEY_ID }}" \
            --issuer "${{ secrets.ASC_ISSUER_ID }}" --wait
          xcrun stapler staple BusyElf.app        # 把公证票钉进 app
          rm AuthKey.p8
          ditto -c -k --keepParent BusyElf.app BusyElf-notarized.zip

      # 4) 挂到 Release
      - uses: softprops/action-gh-release@v2
        with: { files: build/export/BusyElf-notarized.zip }
```

## 需要的 GitHub Secrets

| Secret | 来源 |
|---|---|
| `DEV_ID_P12` | `Developer ID Application` 证书导出的 `.p12`,`base64 -i cert.p12 \| pbcopy` |
| `DEV_ID_P12_PASSWORD` | 导出 `.p12` 时设的密码 |
| `APPLE_TEAM_ID` | 开发者账号 Team ID(10 位) |
| `ASC_API_KEY_P8` | App Store Connect API key `.p8` 的 base64(用于公证) |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` | 该 API key 的 Key ID / Issuer ID |

## 备注

- 用 `git tag vX.Y.Z && git push --tags` 触发发布。
- 想要自动更新可后续接 **Sparkle**(同样全 CLI:生成 appcast、签名 update)。也可做成 `.dmg`(`create-dmg` CLI)替代 zip。
- 本地快速迭代也可保留一份 `Package.swift` 用 `swift build` 跑逻辑,但工程/签名以 XcodeGen+xcodebuild 为准,避免双源维护。
