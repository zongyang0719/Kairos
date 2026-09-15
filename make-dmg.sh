#!/bin/bash
# make-dmg.sh — 构建 Kairos.app 并打包成对外发布的 DMG。
# 用法: sh make-dmg.sh [版本号]   （默认取 git tag；无 tag 必须显式传——对外物必须带版本）
# 铁律：产物给外部用户，每一步独立可验证；任何一步失败即中止。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/kairos-app-src/build/Kairos.app"
OUT_DIR="$SCRIPT_DIR/dist"

# 1. 版本号：显式参数 > git tag
if [[ -n "${1:-}" ]]; then
  VERSION="$1"
else
  VERSION="$(git -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  [[ -n "$VERSION" ]] || { echo "✗ 无 git tag，也没传版本号。对外物必须带版本。" >&2; exit 1; }
fi

# 2. 构建 app（--no-install：产物留 build/，不装本机）
bash "$SCRIPT_DIR/build-kairos.sh" --no-install
[[ -d "$APP_SRC" ]] || { echo "✗ 构建产物不存在：$APP_SRC" >&2; exit 1; }
codesign --verify "$APP_SRC"

# 3. staging：App + 指向 /Applications 的软链（经典拖拽安装）
STAGING="$(mktemp -d /tmp/kairos-dmg.XXXXXX)"
MNT="$(mktemp -d /tmp/kairos-mnt.XXXXXX)"
# trap 修复（2026-09-15）：失败路径若卷仍挂载，rm -rf 挂载点会留孤儿挂载。
# 改为：退出时先查挂载态，挂载着先 detach（不行再 force），卸干净才删目录。
cleanup() {
  # 注意：macOS 上 /tmp 是 /private/tmp 的软链，mount 输出显示的是真实路径，
  # 按 $MNT 前缀 grep 会永远不匹配——所以不做前置判断，直接无条件尝试 detach（没挂载时静默失败）。
  REAL_MNT="$(cd "$MNT" 2>/dev/null && pwd -P)" || REAL_MNT=""
  hdiutil detach "$MNT" >/dev/null 2>&1 || true
  [ -n "$REAL_MNT" ] && [ "$REAL_MNT" != "$MNT" ] && hdiutil detach "$REAL_MNT" >/dev/null 2>&1 || true
  rm -rf "$STAGING"
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
ditto "$APP_SRC" "$STAGING/Kairos.app"
ln -s /Applications "$STAGING/Applications"

# 4. 打包 UDZO（zlib 压缩）
mkdir -p "$OUT_DIR"
DMG_PATH="$OUT_DIR/Kairos-$VERSION.dmg"
rm -f "$DMG_PATH"
hdiutil create -volname Kairos -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH" >/dev/null

# 5. 验证：校验和 + 挂载确认二进制在 + 卸载
hdiutil verify "$DMG_PATH" >/dev/null
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
[[ -x "$MNT/Kairos.app/Contents/MacOS/kairos" ]] || { echo "✗ dmg 内二进制缺失" >&2; exit 1; }
hdiutil detach "$MNT" >/dev/null 2>&1 || true

echo "✓ DMG 就绪：$DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
