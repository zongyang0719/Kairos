#!/bin/bash
# make-zip.sh — 把构建好的 Kairos.app 打成对外发布的干净 zip。
# 关键：ditto --norsrc 不产生 ._* AppleDouble 垃圾。zip -r 会把 ._ 文件混进包里，
# 外部用户解压后 codesign 封条校验失败 →「已损坏，无法打开」（v2.5.0 首发的实际事故）。
# 用法: sh make-zip.sh [版本号]   （默认取 git tag；无 tag 必须显式传）
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/kairos-app-src/build/Kairos.app"
OUT_DIR="$SCRIPT_DIR/dist"
if [[ -n "${1:-}" ]]; then VERSION="$1"; else
  VERSION="$(git -C "$SCRIPT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  [[ -n "$VERSION" ]] || { echo "✗ 无 git tag，也没传版本号。对外物必须带版本。" >&2; exit 1; }
fi
VERSION="v${VERSION#v}"   # 规范化：tag 打成 2.5.1 也能产出 Kairos-v2.5.2-macOS.zip 的命名形态
[[ -d "$APP_SRC" ]] || { echo "✗ 构建产物不存在，先跑: bash build-kairos.sh --no-install" >&2; exit 1; }
codesign --verify --deep --strict "$APP_SRC"   # 进包前封条必须干净
mkdir -p "$OUT_DIR"
ZP="$OUT_DIR/Kairos-$VERSION-macOS.zip"
rm -f "$ZP"
# 源目录先清 AppleDouble/垃圾——ditto --norsrc 挡不住已存在的 ._* 文件（v2.5.1 首包险情）
find "$APP_SRC" \( -name '._*' -o -name '.DS_Store' \) -delete
# 权限位预检：二进制必须可执行，否则外部用户解压后 launchd 拒执行（v2.5.1 实际事故「无法打开」errno 13）
BIN="$APP_SRC/Contents/MacOS/kairos"
[[ -x "$BIN" ]] || { echo "✗ 二进制无可执行位: $BIN — chmod +x 后重跑" >&2; exit 1; }
ditto -c -k --norsrc --keepParent "$APP_SRC" "$ZP"
# 出包后复核：重新解包验封条 + 确认无垃圾文件 + 权限位仍在
TMP="$(mktemp -d /tmp/kairos-zipverify.XXXXXX)"
ditto -x -k "$ZP" "$TMP"
codesign --verify --deep --strict "$TMP/Kairos.app" || { echo "✗ 解包后封条校验失败" >&2; exit 1; }
JUNK="$(find "$TMP" \( -name '._*' -o -name '__MACOSX' -o -name '.DS_Store' \) | head -1)"
[[ -z "$JUNK" ]] || { echo "✗ 包内有垃圾文件: $JUNK" >&2; exit 1; }
[[ -x "$TMP/Kairos.app/Contents/MacOS/kairos" ]] || { echo "✗ 包内二进制丢了执行位——zip 没保留 755，禁发" >&2; exit 1; }
rm -rf "$TMP"
echo "✓ zip 就绪：$ZP ($(du -h "$ZP" | cut -f1))"
echo "  （注：spctl 会判 rejected——未公证的预期结果，README 已写 xattr -cr 说明）"
