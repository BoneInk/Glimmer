#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-steam-library-tests.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/SteamLibraryImport/"*.swift \
  "$ROOT/Tests/SteamLibraryImport/SteamLibraryScannerTests.swift" -o "$WORK/SteamLibraryScannerTests"
"$WORK/SteamLibraryScannerTests" "${1:-$ROOT/evidence/steam-library-import-tests.json}"
