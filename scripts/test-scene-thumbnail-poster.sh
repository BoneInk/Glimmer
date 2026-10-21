#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-thumbnail-poster.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

SCENE_ROOT="${GW_REAL_SCENE_PROJECTS:-$HOME/Library/Application Support/Glimmer/Media/SceneProjects}"
GIF_PROJECT="$SCENE_ROOT/97D203E3-CA37-4E6B-BF90-432F7365AF2C/project.json"
JPEG_PROJECT="$SCENE_ROOT/8AFFB14B-A798-455A-848E-B32B08FBD29C/project.json"

swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/Media/ThumbnailCache.swift" \
  "$ROOT/Tests/SceneThumbnailPosterTests.swift" \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework ImageIO \
  -framework UniformTypeIdentifiers -o "$WORK/probe"

"$WORK/probe" "$WORK/fixtures" "$GIF_PROJECT" "$JPEG_PROJECT"
