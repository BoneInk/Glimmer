#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
WORK="$(mktemp -d /tmp/gw-real-scene-script-modules.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
OUT="${GW_SCENE_MODULE_EVIDENCE:-$ROOT/evidence/scene-script-modules}"
SOURCE_WORKER="${SCENE_SCRIPT_WORKER:-$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker}"
[[ -x "$SOURCE_WORKER" ]] || { printf 'Build the real production SceneScriptWorker first.\n' >&2; exit 2; }
# Freeze executable bytes across all child-process cases even if another build runs.
WORKER="$WORK/GlimmerSceneScriptWorker"
cp "$SOURCE_WORKER" "$WORKER"
mkdir -p "$OUT"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
  "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperTypes.swift" \
  "$ROOT/Sources/Glimmer/SceneWallpaper/SceneScriptSpec.swift" \
  "$ROOT/Sources/Glimmer/SceneWallpaper/SceneHierarchy.swift" \
  "$ROOT/Sources/Glimmer/SceneScript/SceneScriptWorkerClient.swift" \
  "$ROOT/Tests/SceneWallpaper/SceneScriptModuleProbe.swift" -o "$WORK/probe"
"$WORK/probe" "$WORKER" "$OUT/probe.json"
