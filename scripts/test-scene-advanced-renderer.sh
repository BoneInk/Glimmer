#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-advanced-scene.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneAdvancedRendererProbe.swift" -framework ImageIO -framework CoreGraphics -o "$WORK/probe"
"$WORK/probe" "${1:-$ROOT/evidence/scene-advanced-renderer}"
