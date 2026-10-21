#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-lock-export.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 -module-cache-path "$WORK/module-cache" \
 -D GW_UNIVERSAL_SCENE_BACKEND \
 "$ROOT/Sources/SceneBackendShared/SceneBackendTypes.swift" \
 "$ROOT/Sources/Glimmer/SceneBackend/SceneBackendXPCClient.swift" \
 "$ROOT/Sources/Glimmer/SceneBackend/SceneBackendMetalHostView.swift" \
 "$ROOT/Tests/SceneLockScreenExportTests.swift" -o "$WORK/probe"
"$WORK/probe"
