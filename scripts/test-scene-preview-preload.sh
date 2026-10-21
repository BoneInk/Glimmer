#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-preview-preload.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

# Narrow route/model probe. The test supplies a fake Scene runtime and author
# service, so this does not launch the production renderer or touch user data.
swiftc -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos26.0 -parse-as-library \
  -D GW_SCENE_PREVIEW_PRELOAD_TESTS \
  "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
  "$ROOT/Sources/Glimmer/UI/SceneWallpaperPresentation.swift" \
  "$ROOT/Sources/Glimmer/UI/SceneDetailInteractionState.swift" \
  "$ROOT/Sources/Glimmer/UI/SceneWallpaperPreviewPreparation.swift" \
  "$ROOT/Sources/Glimmer/UI/SceneWallpaperPreviewView.swift" \
  "$ROOT/Sources/Glimmer/UI/WorkspaceWallpaperDetails.swift" \
  "$ROOT/Sources/Glimmer/UI/WallpaperCoverSnapshotAlignment.swift" \
  "$ROOT/Tests/SceneWallpaper/ScenePreviewPreloadTests.swift" \
  -framework AppKit -framework SwiftUI \
  -o "$WORK/probe"

"$WORK/probe"
