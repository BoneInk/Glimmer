#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-author-delete-test.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
SOURCES=()
for directory in Steam Store Model Import Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
SOURCES+=(
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentTypes.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentPipe.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentBroker.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentSessionStore.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentProjectDelivery.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentTransferPresentation.swift"
)
source "$ROOT/scripts/author-web-core-sources.sh"
swiftc "${AUTHOR_WEB_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/WorkshopWallpaperApplication.swift" \
  "$ROOT/Sources/Glimmer/Support/ManagedWallpaperDeletionService.swift" \
  "$ROOT/Sources/Glimmer/UI/AuthorProperties/AuthorPropertyEditingCapabilities.swift" \
  "$ROOT/Sources/Glimmer/UI/AuthorProperties/AuthorPropertySettingsSession.swift" \
  "$ROOT/Tests/AuthorWallpaperDeletionTests.swift" -o "$TEST_OUT/AuthorWallpaperDeletionTests"
"$TEST_OUT/AuthorWallpaperDeletionTests"
