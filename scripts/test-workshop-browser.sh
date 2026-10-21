#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-browser-test.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
SOURCES=()
for source in "$ROOT"/Sources/Glimmer/Steam/*.swift; do
  SOURCES+=("$source")
done
SOURCES+=(
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentTypes.swift"
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentPipe.swift"
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentBroker.swift"
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentSessionStore.swift"
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentProjectDelivery.swift"
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentTransferPresentation.swift"
)

source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc "${SCENE_INSPECTION_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/UI/Workshop/WorkshopDownloadProgressPresentation.swift" \
  "$ROOT/Tests/WorkshopBrowserTests.swift" -o "$TEST_OUT/WorkshopBrowserTests"
"$TEST_OUT/WorkshopBrowserTests"
