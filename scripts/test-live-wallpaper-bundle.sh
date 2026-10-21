#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-live-bundle.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
 "$ROOT/Sources/Glimmer/LockScreen/LiveWallpaperBundle.swift" "$ROOT/Tests/LiveWallpaperBundleTests.swift" -o "$WORK/probe"
"$WORK/probe" "$WORK"
