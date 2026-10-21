#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-scene-environment.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
cp "$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker" "$TEMP/GlimmerSceneScriptWorker"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperTypes.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneScriptSpec.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneHierarchy.swift" \
 "$ROOT/Sources/Glimmer/SceneScript/SceneScriptWorkerClient.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneScriptEnvironmentProbe.swift" -o "$TEMP/probe"
"$TEMP/probe" "$TEMP/GlimmerSceneScriptWorker"
