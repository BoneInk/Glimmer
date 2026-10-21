#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-scene-desktop-test.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
SOURCES=()
for directory in Steam SteamContent Store Model Import Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
source "$ROOT/scripts/author-web-core-sources.sh"
swiftc "${AUTHOR_WEB_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/WorkshopWallpaperApplication.swift" \
  "$ROOT/Sources/Glimmer/Support/ManagedWallpaperDeletionService.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneSteamEngineAssetRegistration.swift" \
  "$ROOT/Tests/SceneDesktopIntegrationTests.swift" -o "$TEST_OUT/SceneDesktopIntegrationTests"
"$TEST_OUT/SceneDesktopIntegrationTests"
