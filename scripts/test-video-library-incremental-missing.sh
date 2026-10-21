#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-video-library-incremental.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Store/LibraryPersistence.swift" \
  "$ROOT/Sources/Glimmer/Store/VideoLibraryStore.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/Media/ThumbnailCache.swift" \
  "$ROOT/Tests/VideoLibraryIncrementalMissingTests.swift" \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework ImageIO \
  -o "$WORK/probe"

"$WORK/probe"
