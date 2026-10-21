#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-scene-env-runtime.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
cp "$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker" "$TEMP/GlimmerSceneScriptWorker"
SCENE_SOURCES=()
for file in "$ROOT/Sources/Glimmer/SceneWallpaper/"*.swift; do
  # This suite proves the established CPU/worker path, never the independent Metal prototype.
  case "$(basename "$file")" in MetalScene*) continue ;; esac
  SCENE_SOURCES+=("$file")
done
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/AuthorProperties/"*.swift \
 "${SCENE_SOURCES[@]}" \
 "$ROOT/Sources/Glimmer/SceneScript/"*.swift \
 "$ROOT/Sources/Glimmer/Display/DisplayRegistry.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneEnvironmentRuntimeTests.swift" -o "$TEMP/probe"
"$TEMP/probe" "$TEMP/GlimmerSceneScriptWorker"
