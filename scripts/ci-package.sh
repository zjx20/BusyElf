#!/usr/bin/env bash
#
# CI 打包:为单一架构构建 ad-hoc 签名的 BusyElf.app,产出 zip + dmg 到 dist/。
# 免 Apple 开发者账号路线:ad-hoc 签名(codesign 身份 "-"),不公证。
# 用户下载后需一次性"系统设置 → 隐私与安全性 → 仍要打开"放行(见 docs/BUILD.md / Release 说明)。
#
# 用法(本地可完整复现 CI 的一条腿):
#   ARCH=arm64  REF_NAME=v0.1.0 scripts/ci-package.sh
#   ARCH=x86_64 REF_NAME=v0.1.0 scripts/ci-package.sh
#     ARCH      arm64 | x86_64(GitHub runner 是 arm64,x86_64 为交叉编译)
#     REF_NAME  tag 名(如 v1.2.3);缺省/非法回退 0.0.0
#
# 依赖:xcodegen、xcodebuild、codesign、ditto、hdiutil、lipo(后五个 macOS 自带)。

set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

ARCH="${ARCH:-arm64}"
REF_NAME="${REF_NAME:-}"

# 版本号:去前导 v → 在第一个非法字符处截断(丢 -rc1 / -beta.2 等后缀)→ 规整为"最多三段、
# 纯数字、无前/尾/连续点"的 CFBundleShortVersionString;畸形(空、纯多点等)一律回退 0.0.0。
# MARKETING_VERSION 不合规(尾点 1. / 前导点 ..1 / 超 3 段 1.2.3.4.5)会让 Info.plist 校验失败,故严格兜底。
VER="${REF_NAME#v}"
VER="$(printf '%s' "$VER" | sed -E 's/[^0-9.].*$//; s/\.{2,}/./g; s/^\.+//; s/\.+$//')"
VER="$(printf '%s' "$VER" | awk -F. 'NF{printf "%d.%d.%d",($1==""?0:$1),($2==""?0:$2),($3==""?0:$3)}')"
[ -n "$VER" ] || VER="0.0.0"

echo "==> 架构=$ARCH  版本=$VER  (ref='$REF_NAME')"

command -v xcodegen >/dev/null || { echo "缺 xcodegen(brew install xcodegen)"; exit 1; }
xcodegen generate

# 关键交叉编译开关:ONLY_ACTIVE_ARCH=NO + 显式 ARCHS,否则 arm64 runner 会静默只出 arm64。
# 覆盖工程默认的 Developer ID 为 ad-hoc;关 hardened runtime(那是公证才需要的,ad-hoc 不需要)。
xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
  -derivedDataPath build \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  MARKETING_VERSION="$VER" \
  build

APP="build/Build/Products/Release/BusyElf.app"
[ -d "$APP" ] || { echo "构建产物不存在:$APP"; exit 1; }

# 干净的 ad-hoc 重签:xcodebuild 出的是 linker-signed(codesign --verify 会告警),
# 重签为标准 adhoc 封印,消除告警并保证 zip/dmg 往返后仍有效签名(arm64 必须有效签名才能跑)。
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=2 "$APP"

# 断言架构正确(交叉编译配置错时会静默出错 arch)。
GOT="$(lipo -archs "$APP/Contents/MacOS/BusyElf")"
echo "==> lipo -archs: $GOT"
case " $GOT " in
  *" $ARCH "*) ;;
  *) echo "架构不符:期望 $ARCH,实得 '$GOT'"; exit 1;;
esac

rm -rf dist; mkdir -p dist
BASE="BusyElf-${VER}-${ARCH}"

# 1) zip:ditto 保留 bundle 符号链接 / xattr / 代码签名(绝不用 zip -r,会损坏嵌套签名)。
ditto -c -k --keepParent "$APP" "dist/${BASE}.zip"

# 2) dmg:hdiutil 全程无 Finder/AppleScript(无头 CI 可靠);拖拽到 Applications 的快捷方式;
#    -fs HFS+ 最大兼容(APFS 需较新系统);-format UDZO 压缩只读;-ov 幂等覆盖。
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT   # 失败路径也清理临时目录
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "BusyElf" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "dist/${BASE}.dmg"

echo "==> 产出:"
ls -la dist/
