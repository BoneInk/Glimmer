#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-thumbnail-cache-concurrency.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

# The injected generation operation is exercised for all concurrency cases.
# A tiny Scene stub keeps the unchanged production fallback paths compilable
# without pulling the full renderer into this focused cache probe.
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/Media/ThumbnailCache.swift" \
  "$ROOT/Tests/ThumbnailCacheConcurrencyTests.swift" \
  -framework AppKit -framework AVFoundation -framework CoreGraphics -framework ImageIO \
  -o "$WORK/probe"

"$WORK/probe"
