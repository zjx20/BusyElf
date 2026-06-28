#!/usr/bin/env bash
#
# 一键拉起 BusyElf(Release)。没构建过会自动构建;会先关掉本仓库已在跑的旧实例,避免菜单栏叠图标。
#
# 用法:
#   scripts/run.sh           # 构建(若需要)并后台启动,菜单栏出现 ⚡
#   scripts/run.sh --build   # 强制重新构建再启动
#   scripts/run.sh --debug   # 带 BUSYELF_DEBUG=1 启动(开 /debug/* 端点,便于 curl 调试),日志写 /tmp/busyelf.log
#   scripts/run.sh --stop    # 仅关掉本仓库启动的实例
#   scripts/run.sh --help
#
# 依赖:xcodegen、xcodebuild(构建时);lsof(显示监听端口,可选)。

set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RST=$'\033[0m'

APP="build/Build/Products/Release/BusyElf.app"
BIN="$APP/Contents/MacOS/BusyElf"
FORCE_BUILD=0; DEBUG=0; STOP_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --build) FORCE_BUILD=1 ;;
    --debug) DEBUG=1 ;;
    --stop)  STOP_ONLY=1 ;;
    --help|-h)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "${RED}未知参数:$arg(--help 看用法)${RST}"; exit 1 ;;
  esac
done

# 关掉本仓库 build 目录启动的旧实例。匹配**可执行文件路径** $BIN(=$APP/Contents/MacOS/BusyElf):
# 它的相对形式既是 `--debug` 直跑("$BIN" &)进程的命令行,又是 `open` 经 LaunchServices 启动的
# 绝对命令行的子串 → **同时覆盖两种启动方式**。老版本只匹配绝对 $APP,漏杀 `--debug` 实例(其命令行是
# 相对路径)→ 旧实例占着端口、新实例被挤到回退端口。仍足够具体,绝不误杀用户正常安装的 BusyElf
# (其路径如 /Applications/BusyElf.app,不含 build/Build/…)。
stop_existing() {
  pgrep -f "$BIN" >/dev/null 2>&1 || return 0      # 没有旧实例,直接返回
  pkill -9 -f "$BIN" 2>/dev/null
  echo "${DIM}已关闭旧实例${RST}"
  # 等旧进程真正退出 + 端口释放(SIGKILL 后端口可能短暂滞留),避免新实例被挤到回退端口。
  for _ in $(seq 1 15); do
    pgrep -f "$BIN" >/dev/null 2>&1 || break
    sleep 0.2
  done
  sleep 0.3
}

if [ "$STOP_ONLY" = 1 ]; then
  stop_existing || true
  echo "${GREEN}已停止${RST}"; exit 0
fi

# 构建(缺二进制或 --build 时)。
if [ "$FORCE_BUILD" = 1 ] || [ ! -x "$BIN" ]; then
  echo "${DIM}构建 Release…${RST}"
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null
  if ! xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
        -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
        build >/dev/null 2>&1; then
    echo "${RED}构建失败,请单独跑 xcodebuild 看报错${RST}"; exit 1
  fi
fi
[ -x "$BIN" ] || { echo "${RED}找不到可执行文件:$BIN${RST}"; exit 1; }

stop_existing || true

# 启动。
if [ "$DEBUG" = 1 ]; then
  LOG=/tmp/busyelf.log
  BUSYELF_DEBUG=1 "$BIN" >"$LOG" 2>&1 &
  disown 2>/dev/null || true
  PID=$!
  echo "${GREEN}已启动(debug)${RST} ${DIM}pid=$PID,日志 $LOG,/debug/* 已开${RST}"
else
  open "$APP" || { echo "${RED}启动失败${RST}"; exit 1; }
  sleep 1
  PID=$(pgrep -f "$(pwd)/$APP" | head -1)
  echo "${GREEN}已启动${RST} ${DIM}pid=${PID:-?}${RST}"
fi

# 显示实际监听端口(lsof 可用时;否则看右键菜单顶部"监听:…")。
if [ -n "${PID:-}" ] && command -v lsof >/dev/null; then
  sleep 0.5
  ADDR=$(lsof -nP -iTCP -sTCP:LISTEN -a -p "$PID" 2>/dev/null | awk 'NR>1{print $9}' | head -1)
  [ -n "$ADDR" ] && echo "${DIM}监听:$ADDR(右键菜单顶部也会显示)${RST}"
fi
echo "${BOLD}菜单栏出现 ⚡:左键看任务面板,右键看设置 / 监听地址 / 退出。${RST}"
