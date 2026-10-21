#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-ui-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/scene-inspection-core-sources.sh"
AUTHOR_SOURCES=()
for source in "$ROOT"/Sources/Glimmer/AuthorProperties/*.swift; do
  [[ "$source" == */GWJSONValue.swift ]] || AUTHOR_SOURCES+=("$source")
done
mkdir -p "$ROOT/evidence/scene-wallpaper-ap05"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperCanvasView.swift" \
 "${AUTHOR_SOURCES[@]}" \
 "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
 "$ROOT"/Sources/Glimmer/UI/AuthorProperties/*.swift \
 "$ROOT/Sources/Glimmer/UI/GlassStyle.swift" \
 "$ROOT/Sources/Glimmer/UI/WindowGlassBackdrop.swift" \
 "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
 "$ROOT/Sources/Glimmer/UI/SceneInspectionView.swift" \
 "$ROOT/Sources/Glimmer/UI/PopupSurfaceBackground.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneInspectionUIProbe.swift" \
 -framework AppKit -framework SwiftUI -framework ImageIO -framework CoreGraphics -o "$WORK/probe"
"$WORK/probe" "$ROOT/evidence/scene-wallpaper-ap05/ui-model-probe.json"
