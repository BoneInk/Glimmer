#!/bin/bash
# 从唯一矢量源 Resources/Glimmer.svg 生成 PNG 和完整尺寸的 macOS .icns。
#
# 注意：iconutil 需要 8 位/通道、带 alpha 的 PNG；直接用 NSImage.tiffRepresentation
# 得到的位图会被拒绝，因此这里显式重建 RGBA 位图后再编码 PNG。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/AppIcon.icns"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$ROOT/Resources" "$TMP/AppIcon.iconset"

swiftc -O -o "$TMP/render-icon" "$ROOT/scripts/render-icon.swift" -framework AppKit
"$TMP/render-icon" "$ROOT/Resources/Glimmer.svg" "$TMP/icon-1024.png"
cp "$TMP/icon-1024.png" "$ROOT/Resources/Glimmer.png"

for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" \
            "512:icon_512x512" "1024:icon_512x512@2x"; do
  pixels="${spec%%:*}"
  name="${spec##*:}"
  sips -z "$pixels" "$pixels" "$TMP/icon-1024.png" --out "$TMP/AppIcon.iconset/$name.png" >/dev/null
done

iconutil -c icns "$TMP/AppIcon.iconset" -o "$OUT"
echo "已生成: $OUT"
