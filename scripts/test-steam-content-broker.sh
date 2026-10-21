#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-steam-content-broker.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
for source in "$ROOT"/Sources/Glimmer/Steam/*.swift; do
  [[ "$source" == */WorkshopCoordinator.swift || "$source" == */SteamAccountManager.swift ]] || SOURCES+=("$source")
done
source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc "${SCENE_INSPECTION_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "${SOURCES[@]}" "$ROOT"/Sources/Glimmer/SteamContent/*.swift \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
 "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
 "$ROOT/Tests/SteamContent/SteamContentBrokerTests.swift" -o "$WORK/probe"
"$WORK/probe" "$@"
