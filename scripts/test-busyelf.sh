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

group "权限弹窗:PermissionRequest → waiting(IDE/交互模式真实信号,非 Notification)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"PR","cwd":"/p","prompt":"跑命令"}'
hook '{"hook_event_name":"PreToolUse","session_id":"PR","tool_name":"Bash","tool_input":{"command":"python3 -c x"}}'
expect "PreToolUse → working(即将执行)" "$(st PR)" "working"
hook '{"hook_event_name":"PermissionRequest","session_id":"PR","tool_name":"Bash","tool_input":{"command":"python3 -c x"}}'
expect "PermissionRequest → waiting" "$(st PR)" "waiting"
expect "等批准期间放行休眠" ".blocking" "false"
expect "需批准文案=工具:细节" "$(fld PR waitingMessage)" "需批准 Bash:python3 -c x"
hook '{"hook_event_name":"PostToolUse","session_id":"PR","tool_name":"Bash","tool_input":{"command":"python3 -c x"}}'
expect "批准后 PostToolUse → 复活 working" "$(st PR)" "working"
expect "复活后重新阻止休眠" ".blocking" "true"

group "复活:终态/waiting 被 update 拉回 working(乱序/恢复)"
hook '{"hook_event_name":"PostToolUse","session_id":"A","tool_name":"Edit","tool_input":{"file_path":"a.go"}}'
expect "waiting → working" "$(st A)" "working"
expect "重新阻止休眠" ".blocking" "true"

group "PreToolUse/PostToolUse:动作进行中 → 完成(toolComplete 打 ✓)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"T","cwd":"/p","prompt":"跑测试"}'
hook '{"hook_event_name":"PreToolUse","session_id":"T","tool_name":"Bash","tool_input":{"command":"npm test"}}'
expect "PreToolUse → 即时显示工具" "$(fld T activity)" "Bash: npm test"
expect "进行中 → 未打钩" "$(fld T toolComplete)" "false"
expect "工具进行中仍 working" "$(st T)" "working"
hook '{"hook_event_name":"PostToolUse","session_id":"T","tool_name":"Bash","tool_input":{"command":"npm test"}}'
expect "PostToolUse → 标记完成(✓)" "$(fld T toolComplete)" "true"
expect "✓ 不改 status(仍 working)" "$(st T)" "working"
expect "仍阻止休眠" ".blocking" "true"
hook '{"hook_event_name":"Notification","session_id":"T","notification_type":"permission_prompt","message":"授权?"}'
expect "权限 → waiting,放行休眠" "$(st T)" "waiting"
expect "waiting 放行休眠" ".blocking" "false"
hook '{"hook_event_name":"PostToolUse","session_id":"T","tool_name":"Edit","tool_input":{"file_path":"a.go"}}'
expect "授权后 PostToolUse → 复活 working" "$(st T)" "working"
expect "复活后重新阻止休眠" ".blocking" "true"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"T","prompt":"下一轮"}'
expect "新 turn → 清钩" "$(fld T toolComplete)" "false"

group "阻塞等用户:AskUserQuestion / ExitPlanMode 的 PreToolUse → waiting(放行休眠+点亮关注)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"AQ","cwd":"/p","prompt":"问我点啥"}'
expect "start → 阻止休眠" ".blocking" "true"
hook '{"hook_event_name":"PreToolUse","session_id":"AQ","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"要不要继续?","header":"确认"}]}}'
expect "AskUserQuestion PreToolUse → waiting(不靠 Notification)" "$(st AQ)" "waiting"
expect "等用户期间放行休眠" ".blocking" "false"
expect "提示文案取第一个问题文本" "$(fld AQ waitingMessage)" "要不要继续?"
hook '{"hook_event_name":"PostToolUse","session_id":"AQ","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"要不要继续?"}],"answers":{"要不要继续?":"是"}}}'
expect "用户应答 PostToolUse → 复活 working" "$(st AQ)" "working"
expect "复活后重新阻止休眠" ".blocking" "true"
hook '{"hook_event_name":"PreToolUse","session_id":"AQ","tool_name":"ExitPlanMode","tool_input":{"plan":"第一步...第二步..."}}'
expect "ExitPlanMode PreToolUse → waiting" "$(st AQ)" "waiting"
expect "等批准计划期间放行休眠" ".blocking" "false"
expect "ExitPlanMode 固定提示文案" "$(fld AQ waitingMessage)" "等待批准计划"
hook '{"hook_event_name":"PreToolUse","session_id":"AQ","tool_name":"Bash","tool_input":{"command":"ls"}}'
expect "对照:普通工具 Bash 不进 waiting" "$(st AQ)" "working"

group "PostToolUseFailure:工具失败 → 打 ✗(仍 working,非终态)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"TF","cwd":"/p","prompt":"跑测试"}'
hook '{"hook_event_name":"PostToolUseFailure","session_id":"TF","tool_name":"Bash","tool_input":{"command":"npm test"},"error":"Command exited with non-zero status code 1"}'
expect "失败工具刷新 activity" "$(fld TF activity)" "Bash: npm test"
expect "PostToolUseFailure → toolFailed(✗)" "$(fld TF toolFailed)" "true"
expect "失败原因落库(tooltip 用)" "$(fld TF toolError)" "Command exited with non-zero status code 1"
expect "工具失败不是终态,仍 working" "$(st TF)" "working"
expect "工具失败仍阻止休眠" ".blocking" "true"
expect "工具失败不触发红点(非任务级 failed)" ".hasUnseenFailed" "false"
hook '{"hook_event_name":"PostToolUse","session_id":"TF","tool_name":"Edit","tool_input":{"file_path":"a.go"}}'
expect "下个动作成功 → 清 ✗" "$(fld TF toolFailed)" "false"
expect "下个动作成功 → 打 ✓" "$(fld TF toolComplete)" "true"

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
# 子任务输入(实时关联):父 PreToolUse(Agent) 的 description 暂存 → 紧接的 SubagentStart 领取为子任务 prompt(UI 输入行复用)
hook '{"hook_event_name":"PreToolUse","session_id":"P","tool_name":"Agent","tool_input":{"description":"找 API 端点","prompt":"Find all API endpoints","subagent_type":"Explore"}}'
hook '{"hook_event_name":"SubagentStart","session_id":"P","agent_id":"a2","agent_type":"Explore"}'
expect "子任务输入=Agent 的 description(实时关联)" "$(fld 'P#a2' prompt)" "找 API 端点"
expect "无前置 Agent 调用的子任务则无输入(降级)" "$(fld 'P#a1' prompt)" "null"
hook '{"hook_event_name":"SubagentStop","session_id":"P","agent_id":"a2","last_assistant_message":"done"}'
expect "子任务完成(done)后 prompt 仍在(不消失)" "$(fld 'P#a2' prompt)" "找 API 端点"
hook '{"hook_event_name":"PostToolUse","session_id":"P","agent_id":"a1","agent_type":"Explore","tool_name":"Grep","tool_input":{"pattern":"foo"}}'
expect "子任务工具刷新" "$(fld 'P#a1' activity)" "Grep: foo"
hook '{"hook_event_name":"SubagentStop","session_id":"P","agent_id":"a1","last_assistant_message":"找到 3 处"}'
expect "SubagentStop → 子任务 done" "$(st 'P#a1')" "done"
expect "父任务仍 working" "$(st P)" "working"
expect "子任务完成静默:不点亮菜单栏绿点(父仍 working)" ".hasUnseenDone" "false"
hook '{"hook_event_name":"Stop","session_id":"P","last_assistant_message":"全部完成"}'
expect "父 Stop → done" "$(st P)" "done"
expect "父任务完成 → 点亮菜单栏绿点(子任务不算)" ".hasUnseenDone" "true"
expect "全终态 → 放行休眠" ".blocking" "false"

group "子任务:已完成列表封顶(maxDoneSubtaskCount=20)超出按 endedAt 删最旧"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"P2","cwd":"/proj","prompt":"多子代理主任务"}'
# 起 22 个子代理并全部完成(> 上限 20),父保持 working 不被淘汰
for i in $(seq 0 21); do
  hook "{\"hook_event_name\":\"SubagentStart\",\"session_id\":\"P2\",\"agent_id\":\"a$i\",\"agent_type\":\"Explore\"}"
  hook "{\"hook_event_name\":\"SubagentStop\",\"session_id\":\"P2\",\"agent_id\":\"a$i\",\"last_assistant_message\":\"ok\"}"
done
expect "已完成子任务列表封顶 20" "[.sessions[]|select(.parentId==\"P2\" and .status==\"done\")]|length" "20"
expect "最旧的已完成子任务被移除(a0)" "$(has 'P2#a0')" "false"
expect "次旧的已完成子任务被移除(a1)" "$(has 'P2#a1')" "false"
expect "较新的已完成子任务保留(a21)" "$(has 'P2#a21')" "true"
expect "封顶淘汰仍不点亮绿点(子任务完成静默)" ".hasUnseenDone" "false"

group "需求8:后台进程(Stop.background_tasks)— turn 已结束但后台仍在跑 → 不漏挡休眠"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"BGS","cwd":"/proj","prompt":"起后台进程"}'
expect "start → 阻止休眠" ".blocking" "true"
# Stop 携带在跑 shell:父 done,但后台子项 working(turn 结束、进程仍跑)
hook '{"hook_event_name":"Stop","session_id":"BGS","last_assistant_message":"已在后台启动 build","background_tasks":[{"id":"sh1","type":"shell","status":"running","command":"npm run build"}]}'
expect "父 turn → done" "$(st BGS)" "done"
expect "后台子项创建为 working" "$(st 'BGS#bg:sh1')" "working"
expect "后台子项 parentId=父 session" "$(fld 'BGS#bg:sh1' parentId)" "BGS"
expect "后台子项 name=type(shell)" "$(fld 'BGS#bg:sh1' name)" "shell"
expect "后台子项活动=命令" "$(fld 'BGS#bg:sh1' activity)" "npm run build"
expect "★核心:turn 结束但后台在跑 → 仍阻止休眠" ".blocking" "true"
# 关 popover 不清父(有在跑后台子项,否则子变孤儿)
openpop; closepop
expect "父被保留(有在跑后台子项)" "$(has BGS)" "true"
expect "后台子项仍在" "$(has 'BGS#bg:sh1')" "true"
# 下一轮 Stop 里 shell 消失 → 差集判完成 → 后台子项 done(后台进程退出无事件,只能靠"消失")
hook '{"hook_event_name":"UserPromptSubmit","session_id":"BGS","prompt":"下一轮"}'
hook '{"hook_event_name":"Stop","session_id":"BGS","last_assistant_message":"后台跑完了","background_tasks":[]}'
expect "shell 消失(差集)→ 后台子项 done" "$(st 'BGS#bg:sh1')" "done"
expect "后台全部结束 → 放行休眠" ".blocking" "false"
openpop; closepop
expect "父子全终态 → 清除" "$(has BGS)" "false"
expect "后台子项一并清除" "$(has 'BGS#bg:sh1')" "false"

group "需求8:background_tasks 里的 subagent 不重复折叠(由 SubagentStart/Stop 跟踪)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"BGM","prompt":"混合后台"}'
hook '{"hook_event_name":"Stop","session_id":"BGM","background_tasks":[{"id":"ag9","type":"subagent","status":"running","agent_type":"Explore"},{"id":"sh2","type":"shell","status":"running","command":"tail -f x"}]}'
expect "shell 折叠成后台子项" "$(has 'BGM#bg:sh2')" "true"
expect "subagent 不折叠(无 #bg: 重复项)" "$(has 'BGM#bg:ag9')" "false"
expect "后台 shell 在跑 → 阻止休眠" ".blocking" "true"
# 明确终态状态(如 completed)的条目不折成 working 子项(否则会一直挡休眠到看门狗超时)
hook '{"hook_event_name":"UserPromptSubmit","session_id":"BGT","prompt":"x"}'
hook '{"hook_event_name":"Stop","session_id":"BGT","background_tasks":[{"id":"shC","type":"shell","status":"completed","command":"x"}]}'
expect "明确 completed 的后台条目不折成子项" "$(has 'BGT#bg:shC')" "false"
expect "BGT 无在跑后台 → 父 done 放行(其它会话仍在跑则总体仍阻塞)" "$(st BGT)" "done"

group "子代理 description 兜底:关联器漏接时从 background_tasks 收割补 prompt"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"SD","cwd":"/proj","prompt":"主任务"}'
# 无前置 PreToolUse(Agent) → 关联器领不到 → 子任务 prompt 暂空(漏接场景)
hook '{"hook_event_name":"SubagentStart","session_id":"SD","agent_id":"a1","agent_type":"general-purpose"}'
expect "子任务无前置 Agent → prompt 暂为空" "$(fld 'SD#a1' prompt)" "null"
hook '{"hook_event_name":"PostToolUse","session_id":"SD","agent_id":"a1","tool_name":"Bash","tool_input":{"command":"echo hi"}}'
# SubagentStop 的 background_tasks 含本子代理(type=subagent + description)→ 收割补 prompt
hook '{"hook_event_name":"SubagentStop","session_id":"SD","agent_id":"a1","last_assistant_message":"done","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"扫描端点","agent_type":"general-purpose"}]}'
expect "SubagentStop 从 background_tasks 收割 → 补 prompt" "$(fld 'SD#a1' prompt)" "扫描端点"
expect "富化不改状态(子任务仍 done)" "$(st 'SD#a1')" "done"

group "workflow 子代理:prompt 不在 hook(维持空)+ activity 留存(UI done 态退化锚点用)"
reset
hook '{"hook_event_name":"UserPromptSubmit","session_id":"WS","cwd":"/proj","prompt":"用 workflow 跑评审"}'
hook '{"hook_event_name":"SubagentStart","session_id":"WS","agent_id":"wf1","agent_type":"workflow-subagent"}'
expect "workflow 子代理标签=agent_type" "$(fld 'WS#wf1' name)" "workflow-subagent"
hook '{"hook_event_name":"PostToolUse","session_id":"WS","agent_id":"wf1","tool_name":"Bash","tool_input":{"command":"echo BUSYELF_PROBE_OK"}}'
# SubagentStop 的 background_tasks 是父 workflow(type=workflow)→ 不收割(子代理自身 description 不在此)
hook '{"hook_event_name":"SubagentStop","session_id":"WS","agent_id":"wf1","last_assistant_message":"DONE","background_tasks":[{"id":"job1","type":"workflow","status":"running","description":"评审","name":"review"}]}'
expect "workflow 子代理 prompt 仍空(hook 无此数据)" "$(fld 'WS#wf1' prompt)" "null"
expect "activity(做过的活)留存 → UI done 态退化到锚点显示" "$(fld 'WS#wf1' activity)" "Bash: echo BUSYELF_PROBE_OK"
expect "子代理正常 done" "$(st 'WS#wf1')" "done"

group "需求7:中立 /v1/task/* 与 /claude/hooks 表现力对等(全程中立端点)"
reset
task start  '{"id":"n1","prompt":"修 bug","agent":"my-agent","cwd":"/x"}'
task update '{"id":"n1","tool":"Edit","toolInput":"auth.go"}'
expect "中立 start+update → working" "$(st n1)" "working"
expect "中立 update 缺省 → 未打钩" "$(fld n1 toolComplete)" "false"
task update '{"id":"n1","tool":"Edit","toolInput":"auth.go","toolComplete":true}'
expect "中立 toolComplete 透传 → ✓" "$(fld n1 toolComplete)" "true"
task update '{"id":"n1","tool":"Bash","toolInput":"npm test","toolComplete":true,"toolFailed":true,"toolError":"exit 1"}'
expect "中立 toolFailed 透传 → ✗" "$(fld n1 toolFailed)" "true"
expect "中立 toolError 透传" "$(fld n1 toolError)" "exit 1"
expect "工具失败仍 working" "$(st n1)" "working"
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

group "保活:Stop 见 subagent 后台仍在跑 → 刷新 lastSeen,阻止看门狗误放行休眠"
reset
dbgto 1                                         # 无活动超时 1s(仅测试)
hook '{"hook_event_name":"UserPromptSubmit","session_id":"KA","cwd":"/p","prompt":"起后台子代理"}'
hook '{"hook_event_name":"SubagentStart","session_id":"KA","agent_id":"a1","agent_type":"Explore"}'
expect "子代理创建为 working" "$(st 'KA#a1')" "working"
# 父 Stop:子代理仍在 background_tasks(type=subagent,running)→ 父 done,子代理被 keepAlive 续期(仍 working)
hook '{"hook_event_name":"Stop","session_id":"KA","last_assistant_message":"turn 结束,子代理还在后台跑","background_tasks":[{"id":"a1","type":"subagent","status":"running","agent_type":"Explore"}]}'
expect "父 turn → done" "$(st KA)" "done"
expect "子代理仍 working(未折叠/未 done)" "$(st 'KA#a1')" "working"
expect "★仅子代理在跑 → 仍阻止休眠" ".blocking" "true"
sleep 1.6                                       # 越过 1s 阈值:无新事件 → 看门狗把子代理标 stalled 放行
expect "无刷新 → 看门狗放行休眠" ".blocking" "false"
expect "子代理标记可疑(stalled)" "$(fld 'KA#a1' stalled)" "true"
expect "状态仍 working(未谎报终态)" "$(st 'KA#a1')" "working"
# 再来一个父 Stop:a1 仍列在 background_tasks → keepAlive 刷新 lastSeen → 复活阻止(核心:保活生效)
hook '{"hook_event_name":"Stop","session_id":"KA","last_assistant_message":"还在跑","background_tasks":[{"id":"a1","type":"subagent","status":"running","agent_type":"Explore"}]}'
expect "★Stop 保活刷新 lastSeen → 不再可疑" "$(fld 'KA#a1' stalled)" "false"
expect "★Stop 保活 → 重新阻止休眠" ".blocking" "true"
dbgto 900                                       # 还原默认

group "保活:SubagentStop 见 shell 后台进程仍在跑 → 刷新 lastSeen(SubagentStop 也保活)"
reset
dbgto 1
hook '{"hook_event_name":"UserPromptSubmit","session_id":"KB","cwd":"/p","prompt":"起后台 shell"}'
# 父 Stop 折出后台 shell 子项(working),父 done
hook '{"hook_event_name":"Stop","session_id":"KB","last_assistant_message":"后台跑着","background_tasks":[{"id":"sh1","type":"shell","status":"running","command":"npm run build"}]}'
expect "后台 shell 子项 working" "$(st 'KB#bg:sh1')" "working"
expect "shell 在跑 → 阻止休眠" ".blocking" "true"
sleep 1.6
expect "无刷新 → 看门狗放行" ".blocking" "false"
expect "shell 子项 stalled" "$(fld 'KB#bg:sh1' stalled)" "true"
# 一个子代理结束(SubagentStop),shell 仍列在 background_tasks → keepAlive 刷新 shell 子项(不折叠/不差集)
hook '{"hook_event_name":"SubagentStop","session_id":"KB","agent_id":"x1","last_assistant_message":"子代理完事","background_tasks":[{"id":"sh1","type":"shell","status":"running","command":"npm run build"}]}'
expect "★SubagentStop 保活 shell 子项 → 不再可疑" "$(fld 'KB#bg:sh1' stalled)" "false"
expect "★SubagentStop 保活 → 重新阻止休眠" ".blocking" "true"
expect "shell 子项仍 working(SubagentStop 未误把它 done)" "$(st 'KB#bg:sh1')" "working"
dbgto 900

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

group "配置:语言 env(BUSYELF_LANGUAGE=zh 不破坏启动)"
# i18n 是纯展示层,/debug/state(中立核心)不含任何文案,故 E2E 只能冒烟"设了语言也能正常启动不崩",
# 译文正确性归单元测试(LocalizationTests / ConfigTests)。
LANG_PORT=18932
BUSYELF_DEBUG=1 BUSYELF_LANGUAGE=zh BUSYELF_HTTP_PORT=$LANG_PORT "$BIN" >/dev/null 2>&1 &
LANG_PID=$!
lang_ok=""
for _ in $(seq 1 25); do
  if curl -sS -m1 "http://127.0.0.1:$LANG_PORT/debug/state" 2>/dev/null | grep -q '"blocking"'; then lang_ok=1; break; fi
  sleep 0.2
done
kill "$LANG_PID" 2>/dev/null; wait "$LANG_PID" 2>/dev/null
if [ -n "$lang_ok" ]; then
  PASS=$((PASS+1)); printf "  ${GREEN}✓${RST} BUSYELF_LANGUAGE=zh 实例正常启动\n"
else
  FAIL=$((FAIL+1)); printf "  ${RED}✗ BUSYELF_LANGUAGE=zh 实例启动失败${RST}\n"
fi

group "端口黏住:钉死端口被占 → 不抢占、不漂移(冲突报错而非静默回退)"
# 用 python http.server 占住一个端口,再让"钉死(env)到该端口"的 BusyElf 启动:
# 它应绑定失败、不回退到候选端口、进程不崩(failHard 路径)。
if command -v python3 >/dev/null; then
  BUSY_PORT=18940
  python3 -m http.server "$BUSY_PORT" --bind 127.0.0.1 >/dev/null 2>&1 &
  OCC_PID=$!
  occ_ready=""
  for _ in $(seq 1 25); do
    curl -sS -m1 -o /dev/null "http://127.0.0.1:$BUSY_PORT/" 2>/dev/null && { occ_ready=1; break; }
    sleep 0.2
  done
  if [ -z "$occ_ready" ]; then
    printf "  ${DIM}· 跳过(占位端口未就绪)${RST}\n"
  else
    BUSYELF_DEBUG=1 BUSYELF_HTTP_PORT=$BUSY_PORT "$BIN" >/dev/null 2>&1 &
    CONF_PID=$!
    sleep 1.5
    # 该端口仍是 python 占位(无 BusyElf 的 "blocking" 标记)→ BusyElf 没抢占
    if curl -sS -m1 "http://127.0.0.1:$BUSY_PORT/debug/state" 2>/dev/null | grep -q '"blocking"'; then
      FAIL=$((FAIL+1)); printf "  ${RED}✗ 钉死端口被占时 BusyElf 不应抢占${RST}\n"
    else
      PASS=$((PASS+1)); printf "  ${GREEN}✓${RST} 钉死端口被占 → BusyElf 未抢占该端口\n"
    fi
    if kill -0 "$CONF_PID" 2>/dev/null; then
      PASS=$((PASS+1)); printf "  ${GREEN}✓${RST} 冲突实例存活未崩溃(failHard 而非崩/回退)\n"
    else
      FAIL=$((FAIL+1)); printf "  ${RED}✗ 冲突实例异常退出${RST}\n"
    fi
    kill "$CONF_PID" 2>/dev/null; wait "$CONF_PID" 2>/dev/null
  fi
  kill "$OCC_PID" 2>/dev/null; wait "$OCC_PID" 2>/dev/null
else
  printf "  ${DIM}· 跳过(无 python3)${RST}\n"
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
