#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${1:?Pass the actual workshop project.json to audit without modifying it}"
WORK="$(mktemp -d /tmp/gw-scene-compatibility.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" \
 "$ROOT/Sources/Glimmer/SceneScript/SceneScriptWorkerClient.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneWorkshopCompatibilityProbe.swift" -framework ImageIO -framework CoreGraphics -o "$WORK/probe"
"$WORK/probe" "$1" "${2:-$ROOT/evidence/scene-workshop-3820212613}" "${GW_SCENE_SCRIPT_WORKER:-$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker}"
