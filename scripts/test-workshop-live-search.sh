#!/bin/bash
# Deliberately excluded from offline checks. Only an explicit --live performs public networking.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" != "--live" ]]; then
  echo "Opt-in required: $0 --live [evidence-output.json]" >&2
  exit 64
fi
OUTPUT="${2:-$ROOT/evidence/workshop-web-live-search.json}"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-live-search.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
SOURCES=()
for name in SteamHTTPClient SteamWorkshopModels WorkshopSearchFilters SteamHTML WorkshopSSRParser WorkshopItemPageParser WorkshopPreviewCache WorkshopService; do
  SOURCES+=("$ROOT/Sources/Glimmer/Steam/$name.swift")
done
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Tests/WorkshopWebLiveSearchProbe.swift" -o "$TEST_OUT/WorkshopWebLiveSearchProbe"
"$TEST_OUT/WorkshopWebLiveSearchProbe" --live --evidence "$OUTPUT"
