#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-display-lock-screen.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "$ROOT/Extensions/GlimmerWallpaperExtension/Configuration.swift" \
  "$ROOT/Tests/DisplayLockScreenConfigurationTests.swift" -o "$WORK/probe"
"$WORK/probe"
