#!/usr/bin/env bash
#
# BusyElf E2E 测试:把整套协议/状态机行为沉淀成可复用断言。
#
# 自启一个带 BUSYELF_DEBUG=1 的实例(只读 /debug/state 暴露内部状态,
# queue.sync 兼作写后读屏障 → 断言无需 sleep),逐条验证 7 大需求,跑完自动收尾。
# 不会踩用户已开的正常实例(靠 /debug/state 探测自己启的那个端口)。
#
# 用法:
#   scripts/test-busyelf.sh            # 用已构建的 Release app(没有则自动构建)
#   scripts/test-busyelf.sh --build    # 强制重新构建
#   BUSYELF_BIN=/path/to/BusyElf scripts/test-busyelf.sh   # 指定二进制
#
# 依赖:jq、curl。退出码:全过=0,有失败=1。

set -u
cd "$(cd "$(dirname "$0")/.." && pwd)" || exit 1

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RST=$'\033[0m'
PASS=0; FAIL=0

command -v jq >/dev/null   || { echo "${RED}需要 jq:brew install jq${RST}"; exit 1; }
command -v curl >/dev/null || { echo "${RED}需要 curl${RST}"; exit 1; }

# ── 定位二进制 ──────────────────────────────────────────────
APP="build/Build/Products/Release/BusyElf.app"
BIN="${BUSYELF_BIN:-$APP/Contents/MacOS/BusyElf}"
if [ "${1:-}" = "--build" ] || [ ! -x "$BIN" ]; then
  echo "${DIM}构建 Release…${RST}"
  command -v xcodegen >/dev/null && xcodegen generate >/dev/null
  xcodebuild -project BusyElf.xcodeproj -scheme BusyElf -configuration Release \
    -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build >/dev/null 2>&1 || { echo "${RED}构建失败${RST}"; exit 1; }
fi
[ -x "$BIN" ] || { echo "${RED}找不到可执行文件:$BIN${RST}"; exit 1; }

# ── 启动带 debug 的测试实例,探测它的端口(避开用户已开的实例)──────
BUSYELF_DEBUG=1 "$BIN" >/dev/null 2>&1 &
TEST_PID=$!
cleanup() { kill "$TEST_PID" 2>/dev/null; }
trap cleanup EXIT

PORT=""
for _ in $(seq 1 50); do
  for p in 17872 17873 17874 17875; do
    if curl -sS -m1 "http://127.0.0.1:$p/debug/state" 2>/dev/null | grep -q '"blocking"'; then
      PORT=$p; break 2
    fi
  done
  sleep 0.2
done
[ -n "$PORT" ] || { echo "${RED}测试实例启动超时${RST}"; exit 1; }
BASE="http://127.0.0.1:$PORT"
echo "${DIM}测试实例 pid=$TEST_PID port=$PORT${RST}"

# ── 原语 ────────────────────────────────────────────────────
hook()  { curl -sS -m3 -o /dev/null -X POST "$BASE/claude/hooks" -d "$1"; }     # Claude 专用端点
task()  { curl -sS -m3 -o /dev/null -X POST "$BASE/v1/task/$1" -d "$2"; }       # 中立端点
reset() { curl -sS -m3 -o /dev/null -X POST "$BASE/debug/reset"; }
openpop()  { curl -sS -m3 -o /dev/null -X POST "$BASE/debug/seen"; }   # 模拟打开 popover
closepop() { curl -sS -m3 -o /dev/null -X POST "$BASE/debug/purge"; }  # 模拟关闭 popover
dbgto() { curl -sS -m3 -o /dev/null -X POST "$BASE/debug/timeout" -d "$1"; }  # 设无活动超时(秒)
state() { curl -sS -m3 "$BASE/debug/state"; }

# 断言:expect "描述" "jq 过滤器" "期望值"
expect() {
  local got; got=$(state | jq -r "$2" 2>/dev/null)
  if [ "$got" = "$3" ]; then
    PASS=$((PASS+1)); printf "  ${GREEN}✓${RST} %s ${DIM}(%s = %s)${RST}\n" "$1" "$2" "$3"
  else
    FAIL=$((FAIL+1)); printf "  ${RED}✗ %s${RST}  ${DIM}%s → 期望[%s] 实得[%s]${RST}\n" "$1" "$2" "$3" "$got"
  fi
}
group() { printf "\n${BOLD}%s${RST}\n" "$1"; }

# jq 速记
st()  { echo ".sessions[]|select(.id==\"$1\")|.status"; }       # 某 id 的 status
fld() { echo ".sessions[]|select(.id==\"$1\")|.$2"; }           # 某 id 的字段
has() { echo "([.sessions[].id]|index(\"$1\"))!=null"; }        # 某 id 是否存在

# ── 用例 ────────────────────────────────────────────────────

group "需求1:中途接管(漏 start,见到活动就追踪)"
reset
hook '{"hook_event_name":"PostToolUse","session_id":"A","cwd":"/p","tool_name":"Bash","tool_input":{"command":"npm test"}}'
expect "PostToolUse 无 start 也创建 working" "$(st A)" "working"
expect "阻止休眠" ".blocking" "true"
expect "活动行=工具:细节" "$(fld A activity)" "Bash: npm test"

group "需求1:权限等待用 notification_type 区分;idle 不产生幽灵项"
hook '{"hook_event_name":"Notification","session_id":"A","notification_type":"permission_prompt","message":"授权?"}'
expect "permission_prompt → waiting" "$(st A)" "waiting"
expect "waiting 放行休眠" ".blocking" "false"
hook '{"hook_event_name":"Notification","session_id":"GHOST","notification_type":"idle_prompt","message":"等下一句"}'
expect "idle_prompt 不创建幽灵项" "$(has GHOST)" "false"
expect "仍只有 1 个任务" ".count" "1"

group "复活:终态/waiting 被 update 拉回 working(乱序/恢复)"
hook '{"hook_event_name":"PostToolUse","session_id":"A","tool_name":"Edit","tool_input":{"file_path":"a.go"}}'
expect "waiting → working" "$(st A)" "working"
expect "重新阻止休眠" ".blocking" "true"

group "需求2:Stop → done(不删,绿点)+ seen 生命周期"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"D","cwd":"/proj","prompt":"重构 auth"}'
hook '{"hook_event_name":"Stop","session_id":"D","last_assistant_message":"已完成,改了 3 个文件。"}'
expect "Stop → done(item 留存)" "$(st D)" "done"
expect "done 放行休眠" ".blocking" "false"
expect "未看完成 → 绿点" ".hasUnseenDone" "true"
expect "最终回复落库" "$(fld D reply)" "已完成,改了 3 个文件。"
openpop   # 模拟打开 popover
expect "打开 popover → 标 seen(清绿点)" ".hasUnseenDone" "false"
expect "本次打开仍能看到 done" "$(has D)" "true"
closepop  # 模拟关闭
expect "关闭后清理 → 下次打开消失" "$(has D)" "false"

group "需求3:StopFailure → failed(红点 + 原因/细节)"
reset
hook '{"hook_event_name":"StopFailure","session_id":"E","error":"rate_limit","last_assistant_message":"API Error: Rate limit reached"}'
expect "StopFailure 直接新建 failed" "$(st E)" "failed"
expect "未看失败 → 红点" ".hasUnseenFailed" "true"
expect "failed 放行休眠" ".blocking" "false"
expect "失败类型" "$(fld E errorKind)" "rate_limit"
expect "失败细节" "$(fld E errorDetail)" "API Error: Rate limit reached"
hook '{"hook_event_name":"Stop","session_id":"E","last_assistant_message":"x"}'
expect "失败优先:done 不覆盖 failed" "$(st E)" "failed"

group "需求5:MessageDisplay 流式回复(replace/append)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"F","prompt":"p"}'
hook '{"hook_event_name":"MessageDisplay","session_id":"F","index":0,"delta":"X"}'
hook '{"hook_event_name":"MessageDisplay","session_id":"F","index":1,"delta":"Y"}'
expect "首批 replace + 续批 append = XY" "$(fld F reply)" "XY"
hook '{"hook_event_name":"MessageDisplay","session_id":"F","index":0,"delta":"Z"}'
expect "新消息 index0 → replace 为 Z" "$(fld F reply)" "Z"

group "需求6:subagent(session 同、agent_id 折进 id、parentId 关联)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"P","cwd":"/proj","prompt":"主任务"}'
hook '{"hook_event_name":"SubagentStart","session_id":"P","agent_id":"a1","agent_type":"Explore"}'
expect "子任务 id = session#agent" "$(has 'P#a1')" "true"
expect "子任务 parentId=父 session" "$(fld 'P#a1' parentId)" "P"
expect "子任务标签=agent_type" "$(fld 'P#a1' name)" "Explore"
expect "子任务 working 也阻止休眠" ".blocking" "true"
hook '{"hook_event_name":"PostToolUse","session_id":"P","agent_id":"a1","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"foo"}}'
expect "子任务工具刷新" "$(fld 'P#a1' activity)" "Grep: foo"
hook '{"hook_event_name":"SubagentStop","session_id":"P","agent_id":"a1","last_assistant_message":"找到 3 处"}'
expect "SubagentStop → 子任务 done" "$(st 'P#a1')" "done"
expect "父任务仍 working" "$(st P)" "working"
hook '{"hook_event_name":"Stop","session_id":"P","last_assistant_message":"全部完成"}'
expect "父 Stop → done" "$(st P)" "done"
expect "全终态 → 放行休眠" ".blocking" "false"

group "需求7:中立 /v1/task/* 与 /claude/hooks 表现力对等(全程中立端点)"
reset
task start  '{"id":"n1","prompt":"修 bug","agent":"my-agent","cwd":"/x"}'
task update '{"id":"n1","tool":"Edit","toolInput":"auth.go"}'
expect "中立 start+update → working" "$(st n1)" "working"
task start  '{"id":"n1#s","parentId":"n1","name":"Explore"}'
expect "中立子任务折叠 id + parentId" "$(fld 'n1#s' parentId)" "n1"
task "done" '{"id":"n1#s","reply":"扫描完成"}'
expect "中立子任务 done" "$(st 'n1#s')" "done"
task update '{"id":"n1","reply":"AAA","replyAppend":false}'
task update '{"id":"n1","reply":"BBB","replyAppend":true}'
expect "中立 reply replace/append = AAABBB" "$(fld n1 reply)" "AAABBB"
task wait   '{"id":"n1","message":"确认?"}'
expect "中立 wait → waiting" "$(st n1)" "waiting"
task "done" '{"id":"n1","reply":"已提交"}'
expect "中立 done → done" "$(st n1)" "done"
task fail   '{"id":"n2","errorKind":"overloaded","errorDetail":"过载"}'
expect "中立 fail 新建 → failed" "$(st n2)" "failed"
task remove '{"id":"n2"}'
expect "中立 remove → 消失" "$(has n2)" "false"

group "需求7:remove 级联子任务"
reset
task start '{"id":"P2","prompt":"x"}'
task start '{"id":"P2#c","parentId":"P2","name":"sub"}'
task remove '{"id":"P2"}'
expect "remove 父 → 子任务一并移除" ".count" "0"

group "看门狗:working 长时间无活动 → 放行休眠(标记可疑、可逆)"
reset
dbgto 1                                       # 无活动超时设为 1s(仅测试)
task start '{"id":"W","prompt":"长任务","cwd":"/x"}'
expect "刚启动 → working" "$(st W)" "working"
expect "阻止休眠(派生)" ".blocking" "true"
expect "电源断言已持有" ".assertionHeld" "true"
expect "未超时 → 未标可疑" "$(fld W stalled)" "false"
sleep 1.6                                      # 越过 1s 阈值 + 余量,等看门狗 timer 自行 fire
expect "超时 → 放行休眠(派生)" ".blocking" "false"
expect "看门狗已释放电源断言" ".assertionHeld" "false"
expect "状态仍 working(未谎报终态)" "$(st W)" "working"
expect "标记为可疑(stalled)" "$(fld W stalled)" "true"
expect "任务仍保留" "$(has W)" "true"
task update '{"id":"W","tool":"Edit","detail":"a.go"}'
expect "收到新进展 → 复活,重新阻止休眠" ".blocking" "true"
expect "电源断言重新持有" ".assertionHeld" "true"
expect "不再可疑" "$(fld W stalled)" "false"
dbgto 900                                      # 还原默认,避免影响后续

group "配置:自定义端口(BUSYELF_HTTP_PORT 首选端口生效)"
CUSTOM_PORT=18931
BUSYELF_DEBUG=1 BUSYELF_HTTP_PORT=$CUSTOM_PORT "$BIN" >/dev/null 2>&1 &
PORT_PID=$!
port_ok=""
for _ in $(seq 1 25); do
  if curl -sS -m1 "http://127.0.0.1:$CUSTOM_PORT/debug/state" 2>/dev/null | grep -q '"blocking"'; then port_ok=1; break; fi
  sleep 0.2
done
kill "$PORT_PID" 2>/dev/null; wait "$PORT_PID" 2>/dev/null   # wait 收尾,抑制 job-control "Terminated" 噪声
if [ -n "$port_ok" ]; then
  PASS=$((PASS+1)); printf "  ${GREEN}✓${RST} 实例监听自定义端口 %s\n" "$CUSTOM_PORT"
else
  FAIL=$((FAIL+1)); printf "  ${RED}✗ 自定义端口 %s 不可达${RST}\n" "$CUSTOM_PORT"
fi

group "容错:坏 body / 缺 id 仍 200 不崩、不影响状态"
reset
curl -sS -m3 -o /dev/null -w '' -X POST "$BASE/v1/task/start" -d 'not-json'
curl -sS -m3 -o /dev/null -X POST "$BASE/v1/task/start" -d '{"prompt":"无 id"}'
hook 'garbage-not-json'
expect "坏输入不产生任何任务" ".count" "0"
if kill -0 "$TEST_PID" 2>/dev/null; then
  PASS=$((PASS+1)); printf '  %s✓%s 进程存活(未崩溃)\n' "$GREEN" "$RST"
else
  FAIL=$((FAIL+1)); printf '  %s✗ 进程崩溃%s\n' "$RED" "$RST"
fi

# ── 汇总 ────────────────────────────────────────────────────
printf "\n${BOLD}结果:${GREEN}%d 通过${RST}${BOLD},%s%d 失败${RST}\n" "$PASS" "$([ "$FAIL" -gt 0 ] && echo "$RED" || echo "$DIM")" "$FAIL"
[ "$FAIL" -eq 0 ]
