#!/bin/bash
# 从 1024px 主图生成 macOS 多尺寸 PNG 与 AppIcon.icns
set -e
cd "$(dirname "$0")"

MASTER="icon-master.png"
PNG_DIR="icon-png"
ICONSET="icon.iconset"
ICNS="AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
  echo "缺少 $MASTER" >&2
  exit 1
fi

mkdir -p "$PNG_DIR" "$ICONSET"

make_png() {
  local size=$1 out=$2
  sips -z "$size" "$size" "$MASTER" --out "$out" >/dev/null
}

# 独立 PNG（16/32/64/128/256/512/1024）
for size in 16 32 64 128 256 512 1024; do
  make_png "$size" "$PNG_DIR/icon-${size}.png"
done

# iconutil 所需的 iconset 命名
make_png 16  "$ICONSET/icon_16x16.png"
make_png 32  "$ICONSET/icon_16x16@2x.png"
make_png 32  "$ICONSET/icon_32x32.png"
make_png 64  "$ICONSET/icon_32x32@2x.png"
make_png 128 "$ICONSET/icon_128x128.png"
make_png 256 "$ICONSET/icon_128x128@2x.png"
make_png 256 "$ICONSET/icon_256x256.png"
make_png 512 "$ICONSET/icon_256x256@2x.png"
make_png 512 "$ICONSET/icon_512x512.png"
cp "$PNG_DIR/icon-1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"

echo "=== 图标 ==="
echo "  Master: $(pwd)/$MASTER"
echo "  PNG:    $(pwd)/$PNG_DIR/"
echo "  ICNS:   $(pwd)/$ICNS"
file "$ICNS"
