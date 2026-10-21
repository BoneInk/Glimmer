#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${1:?Pass the actual target project.json}"
WORK="$(mktemp -d /tmp/gw-target-scene.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "$ROOT"/Sources/Glimmer/AuthorProperties/*.swift \
 "$ROOT"/Sources/Glimmer/AuthorPropertyAssets/*.swift \
 "$ROOT"/Sources/Glimmer/WebWallpaper/*.swift \
 "$ROOT"/Sources/Glimmer/SceneWallpaper/*.swift \
 "$ROOT"/Sources/Glimmer/SceneScript/*.swift \
 "$ROOT"/Sources/Glimmer/Model/*.swift \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Support/AuthorPropertyServices.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneTargetGraphProbe.swift" -framework AppKit -lcompression -o "$WORK/probe"
ARGS=("$1" "${2:-$ROOT/evidence/scene-target13-synthetic-engine-fixture}" "${GW_SCENE_SCRIPT_WORKER:-$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker}")
if [[ $# -ge 3 ]]; then ARGS+=("$3"); fi
"$WORK/probe" "${ARGS[@]}"
