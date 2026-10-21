#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-script-parser.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
source "$ROOT/scripts/scene-inspection-core-sources.sh"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Tests/SceneWallpaper/SceneScriptParserTests.swift" -o "$WORK/probe"
"$WORK/probe"
