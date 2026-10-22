#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glimmer-information.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
for source in SteamWorkshopModels SteamHTTPClient SteamHTML WorkshopSearchFilters WorkshopItemPageParser WorkshopSSRParser WorkshopService WorkshopPreviewCache WorkshopInformationModel; do
 SOURCES+=("$ROOT/Sources/Glimmer/Steam/$source.swift")
done
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "${SOURCES[@]}" "$ROOT/Sources/Glimmer/Store/AppStorage.swift" "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Tests/WorkshopInformationTests.swift" -o "$WORK/probe"
"$WORK/probe" "$@"
