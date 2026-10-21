#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-project-backend.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
source "$ROOT/scripts/scene-inspection-core-sources.sh"
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

swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "${SOURCES[@]}" \
 "$ROOT/Sources/Glimmer/SceneWallpaper/SceneWallpaperRenderer.swift" "$ROOT/Sources/Glimmer/SceneWallpaper/SceneAdvancedRenderer.swift" \
 "$ROOT"/Sources/Glimmer/Model/*.swift "$ROOT"/Sources/Glimmer/Store/*.swift \
 "$ROOT"/Sources/Glimmer/Import/*.swift "$ROOT"/Sources/Glimmer/SteamLibraryImport/*.swift \
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" "$ROOT/Sources/Glimmer/Media/ThumbnailCache.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" "$ROOT/Sources/Glimmer/Support/WebWallpaperProject.swift" \
 "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" "$ROOT/Sources/Glimmer/Support/SceneProjectImporter.swift" \
 "$ROOT/Tests/SceneProjectBackendTests.swift" -o "$WORK/probe"
"$WORK/probe"
