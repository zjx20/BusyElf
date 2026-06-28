#!/usr/bin/env bash
#
# BusyElf 单元测试(白盒):TaskStore 状态机 / ClaudeHookEvent 映射 / TaskEvent 解析。
# 跑 XCTest 宿主测试(AppDelegate 在 XCTest 下跳过 app 装配,纯测内部逻辑)。
#
# 用法:scripts/test-unit.sh
# 依赖:xcodegen、xcodebuild。退出码透传 xcodebuild。

set -eu
cd "$(cd "$(dirname "$0")/.." && pwd)"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

exec xcodebuild test \
  -project BusyElf.xcodeproj -scheme BusyElf -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=NO \
  "$@"
