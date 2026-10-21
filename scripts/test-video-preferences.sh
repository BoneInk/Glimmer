#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-video-preferences.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/author-web-core-sources.sh"
swiftc "${AUTHOR_WEB_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Store/LibraryPersistence.swift" \
  "$ROOT/Sources/Glimmer/Store/VideoLibraryStore.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/Media/ThumbnailCache.swift" \
  "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift" \
  "$ROOT/Sources/Glimmer/Display/DisplayRegistry.swift" \
  "$ROOT/Sources/Glimmer/Desktop/DesktopWallpaperController.swift" \
  "$ROOT/Tests/VideoPlaybackPreferencesTests.swift" -o "$WORK/probe"
"$WORK/probe"
