#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-presentation.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -parse-as-library \
 "$ROOT/Sources/Glimmer/UI/SceneWallpaperPresentation.swift" \
 "$ROOT/Tests/SceneWallpaper/ScenePresentationTests.swift" -o "$WORK/probe"
"$WORK/probe"
