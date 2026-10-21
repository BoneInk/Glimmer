#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-content-delivery-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
for source in "$ROOT"/Sources/Glimmer/Steam/*.swift; do
  case "$(basename "$source")" in SteamAccountManager.swift|WorkshopCoordinator.swift) ;; *) SOURCES+=("$source") ;; esac
done
source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc "${SCENE_INSPECTION_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "${SOURCES[@]}" \
 "$ROOT"/Sources/Glimmer/Model/*.swift \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
 "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Support/SceneProjectDescriptor.swift" \
 "$ROOT/Tests/SteamContent/DownloadMetadataRecoveryTests.swift" -o "$WORK/probe"
"$WORK/probe"
