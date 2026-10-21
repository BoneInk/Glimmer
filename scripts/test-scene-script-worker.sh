#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p build/SceneScriptWorkerProbe evidence/scene-script-worker
worker="${SCENE_SCRIPT_WORKER:-$PWD/build/SceneScriptWorker/GlimmerSceneScriptWorker}"
[[ -x "$worker" ]] || { print -u2 'Build the production SceneScriptWorker first'; exit 1; }
xcrun swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  Sources/Glimmer/AuthorProperties/GWJSONValue.swift \
  Sources/Glimmer/SceneWallpaper/SceneWallpaperTypes.swift \
  Sources/Glimmer/SceneWallpaper/SceneScriptSpec.swift \
  Sources/Glimmer/SceneWallpaper/SceneHierarchy.swift \
  Sources/Glimmer/SceneScript/SceneScriptWorkerClient.swift \
  Tests/SceneWallpaper/SceneScriptWorkerProbe.swift \
  -o build/SceneScriptWorkerProbe/probe
build/SceneScriptWorkerProbe/probe "$worker" | tee evidence/scene-script-worker/probe.json
