#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-shader-cache.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
    "$ROOT/Sources/Glimmer/SceneBackend/SceneBackendPrivateCache.swift" \
    "$ROOT/Sources/Glimmer/SceneBackend/SceneBackendShaderCache.swift" \
    "$ROOT/Tests/SceneWallpaper/SceneBackendShaderCacheTests.swift" -o "$WORK/probe"
"$WORK/probe" "$WORK"
