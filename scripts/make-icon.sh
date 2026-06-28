#!/usr/bin/env bash
#
# 从 design/AppIcon.svg 生成 Resources/AppIcon.icns(全尺寸)。
# icns 已入库,平时无需跑此脚本;仅在改了 AppIcon.svg 后用它重生成。
#
# 依赖:
#   - 一个能保留透明的 SVG 光栅化器(按优先级探测):
#       rsvg-convert(brew install librsvg) / npx sharp-cli(零安装,联网拉一次) / magick
#     注意:不要用 qlmanage —— 它给 SVG 垫白底,圆角外会变成白边。
#   - sips、iconutil(macOS 自带)
#
# 用法:scripts/make-icon.sh

set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

SVG="design/AppIcon.svg"
OUT="Resources/AppIcon.icns"
[ -f "$SVG" ] || { echo "找不到 $SVG"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MASTER="$TMP/master-1024.png"

# 1) 渲染 1024 主图(必须保留透明)
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 "$SVG" -o "$MASTER"
elif command -v magick >/dev/null 2>&1; then
  magick -background none "$SVG" -resize 1024x1024 "$MASTER"
else
  echo "用 npx sharp-cli 渲染(首次会联网安装)…"
  npx --yes sharp-cli --input "$SVG" --output "$MASTER" resize 1024 1024
fi

# 校验透明:角落像素 alpha 必须为 0,否则换光栅化器
ALPHA="$(sips -g hasAlpha "$MASTER" 2>/dev/null | awk '/hasAlpha/{print $2}')"
[ "$ALPHA" = "yes" ] || { echo "主图无透明通道,换光栅化器(别用 qlmanage)"; exit 1; }

# 2) 由 1024 主图缩出 iconset 各尺寸(Apple 命名约定)
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

# 3) 打包成 .icns
iconutil -c icns "$ICONSET" -o "$OUT"
echo "已生成 $OUT"
sips -g pixelWidth -g pixelHeight "$OUT" 2>/dev/null | sed 's/^/  /' || true
