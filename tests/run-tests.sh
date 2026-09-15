#!/usr/bin/env bash
# 一条命令跑完两侧的测试。
#
# Swift 侧的 suite 不是自足的：它们只写断言，被测的类型都在 kairos-app-src/ 里，
# 必须和源文件一起编。少一个就是满屏 "cannot find X in scope"——那不是测试挂了，
# 是编译命令不对。排除的五个是 macOS SwiftUI 界面，测试用不到。
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=()
for f in kairos-app-src/*.swift; do
  case "$(basename "$f")" in
    KairosApp.swift|KairosViews.swift|KairosRoomView.swift|KairosInboxView.swift|KairosOnboardingView.swift) continue ;;
  esac
  SOURCES+=("$f")
done

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

echo "=== Node ==="
node --test tests/ledger.test.js tests/mail.test.js

for suite in native-ledger native-location native-mail native-markdown native-message native-stream native-workspace; do
  echo "=== Swift · $suite ==="
  swiftc -o "$BUILD/$suite" "tests/$suite/main.swift" "${SOURCES[@]}"
  "$BUILD/$suite"
done

echo "=== iOS · 编译检查 ==="
# 只发 Mac 的时候，iOS 那 8 个界面没人编就会悄悄烂掉（共享的核心文件上面已经测过了）。
# 这一步不签名、不装机、不跑模拟器，只确认它还编得过。没装 Xcode 就跳过。
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -project KairosiOS.xcodeproj -scheme Kairos \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO build >/dev/null
  echo "iOS 编译通过。"
else
  echo "没找到 xcodebuild，跳过。"
fi

echo "全部通过。"
