#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-workshop-web.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
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
swiftc -disable-sandbox "${SCENE_INSPECTION_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "${SOURCES[@]}" \
 "$ROOT"/Sources/Glimmer/Model/*.swift \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
 "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" \
 "$ROOT/Tests/WorkshopWebProjectTests.swift" -o "$WORK/probe"
"$WORK/probe"
