#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-manifest-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR=/private/tmp/glimmer-tmp
export CLANG_MODULE_CACHE_PATH=/private/tmp/glimmer-clang-module-cache
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" /private/tmp/glimmer-swift-module-cache

SOURCES=()
for source in "$ROOT"/Sources/Glimmer/Steam/*.swift; do
  [[ "$(basename "$source")" == WorkshopCoordinator.swift ]] || SOURCES+=("$source")
done
SOURCES+=(
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentTypes.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentPipe.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentBroker.swift"
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentSessionStore.swift"
)
source "$ROOT/scripts/scene-inspection-core-sources.sh"

swiftc -disable-sandbox \
  -module-cache-path /private/tmp/glimmer-swift-module-cache \
  "${SCENE_INSPECTION_CORE_SOURCES[@]}" \
  -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT"/Sources/Glimmer/Model/*.swift \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" \
  "$ROOT/Tests/GlimmerDownloadManifestCompatibilityTests.swift" \
  -o "$WORK/GlimmerDownloadManifestCompatibilityTests"

"$WORK/GlimmerDownloadManifestCompatibilityTests"
