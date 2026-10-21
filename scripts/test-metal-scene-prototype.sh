#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-metal-scene.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneScriptSpec.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperTypes.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneHierarchy.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/MetalScenePassGraph.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/MetalSceneCompositor.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/MetalSceneInspectionAdapter.swift" \
 "$ROOT/Tests/SceneWallpaper/MetalPrototype/MetalScenePrototypeTests.swift" \
 -o "$TEST_OUT/MetalScenePrototypeTests"
"$TEST_OUT/MetalScenePrototypeTests" "$@"
