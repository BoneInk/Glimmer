#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/scene-inspection-core-sources.sh"
mkdir -p "$ROOT/evidence/scene-wallpaper-ap05"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperCanvasView.swift" "$ROOT/Tests/SceneWallpaper/SceneWallpaperProbe.swift" \
 -framework ImageIO -framework CoreGraphics -framework AppKit -o "$WORK/probe"
"$WORK/probe" "$ROOT/evidence/scene-wallpaper-ap05/probe.json"

mkdir -p "$ROOT/evidence/scene-texture-codecs"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperCanvasView.swift" "$ROOT/Tests/SceneWallpaper/SceneTextureCodecProbe.swift" \
 -framework ImageIO -framework CoreGraphics -framework AppKit -lcompression -o "$WORK/texture-probe"
"$WORK/texture-probe" "$ROOT/evidence/scene-texture-codecs/probe.json"
