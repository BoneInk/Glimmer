#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="${GW_SCENE_SCRIPT_WORKER:-$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker}"
WORK="$(mktemp -d /tmp/gw-scene-script-runtime.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p "$ROOT/evidence/scene-script-runtime"
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
 "$ROOT/Tests/SceneWallpaper/SceneSpriteParticleRuntimeProbe.swift" \
 -framework AppKit -lcompression -o "$WORK/probe"
"$WORK/probe" "${1:-$ROOT/evidence/scene-sprite-particles/runtime-probe.json}"
"$WORK/probe" "$ROOT/evidence/scene-sprite-particles/advanced-runtime-probe.json" --advanced
