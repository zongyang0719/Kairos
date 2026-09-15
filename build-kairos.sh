#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Kairos"
SRC_DIR="$SCRIPT_DIR/kairos-app-src"
BUILD_DIR="$SRC_DIR/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
INSTALL_APP=true

if [[ "${1:-}" == "--no-install" ]]; then
  INSTALL_APP=false
fi

echo "=== 发布门禁：Team ID 必须为空 ==="
if grep -q 'DEVELOPMENT_TEAM = "[^"]' "$SCRIPT_DIR/KairosiOS.xcodeproj/project.pbxproj"; then
  echo "✗ DEVELOPMENT_TEAM 不是空——这是私人信息，不进对外仓。" >&2
  echo "  本地 Xcode 选完签名后不要提交回来；清掉再发版。" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "=== 生成图标 ==="
bash "$SRC_DIR/make-icon.sh"

echo "=== 编译 arm64 ==="
swiftc -O -target arm64-apple-macos26.0 \
  -o "$BUILD_DIR/kairos-arm" "$SRC_DIR"/*.swift \
  -framework Cocoa -framework SwiftUI

echo "=== 编译 x86_64 ==="
swiftc -O -target x86_64-apple-macos26.0 \
  -o "$BUILD_DIR/kairos-x86" "$SRC_DIR"/*.swift \
  -framework Cocoa -framework SwiftUI

echo "=== 合并 universal binary ==="
lipo -create "$BUILD_DIR/kairos-arm" "$BUILD_DIR/kairos-x86" -output "$BUILD_DIR/kairos"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BUILD_DIR/kairos" "$APP_PATH/Contents/MacOS/kairos"
cp "$SRC_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
# 「请求规则」确认页的预览真源：对外发布走 overrides 版，有则优先
RULES_SRC="$SCRIPT_DIR/release-overrides/BEING-RULES.md"
[[ -f "$RULES_SRC" ]] || RULES_SRC="$SCRIPT_DIR/BEING-RULES.md"
cp "$RULES_SRC" "$APP_PATH/Contents/Resources/BEING-RULES.md"
cp "$SRC_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"

codesign --force --deep --sign - "$APP_PATH"
codesign --verify "$APP_PATH"

if [[ "$INSTALL_APP" == true ]]; then
  INSTALLED_PATH="/Applications/$APP_NAME.app"
  rm -rf "$INSTALLED_PATH"
  ditto "$APP_PATH" "$INSTALLED_PATH"
  # 装完把中间产物清掉：留着的话磁盘上就有两个 Kairos.app，Spotlight 和启动台
  # 两个都索引，点开的可能是上一次 build 的那份。--no-install 时才留着给人自己拿。
  rm -rf "$APP_PATH"
  echo "=== 已安装到 $INSTALLED_PATH ==="
else
  echo "=== 已构建（未安装）：$APP_PATH ==="
fi
