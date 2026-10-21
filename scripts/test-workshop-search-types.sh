#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-search-types.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/Steam/SteamWorkshopModels.swift" \
 "$ROOT/Sources/Glimmer/Steam/WorkshopSearchFilters.swift" \
 "$ROOT/Sources/Glimmer/Steam/WorkshopBrowserStore.swift" \
 "$ROOT/Sources/Glimmer/Steam/SteamHTML.swift" \
 "$ROOT/Sources/Glimmer/Steam/SteamHTTPClient.swift" \
 "$ROOT/Sources/Glimmer/Steam/WorkshopSSRParser.swift" \
 "$ROOT/Tests/WorkshopSearchTypeTests.swift" -o "$WORK/probe"
"$WORK/probe"
