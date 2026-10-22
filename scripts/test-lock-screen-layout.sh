#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-lock-screen-layout.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
 "$ROOT/Sources/Glimmer/UI/GlassStyle.swift" \
 "$ROOT/Sources/Glimmer/UI/WindowGlassBackdrop.swift" \
 "$ROOT/Sources/Glimmer/UI/WallpaperActionLabel.swift" \
 "$ROOT/Sources/Glimmer/UI/LockScreenInlineControls.swift" \
 "$ROOT/Tests/LockScreenInlineControlsLayoutTests.swift" -o "$WORK/probe"
"$WORK/probe"
