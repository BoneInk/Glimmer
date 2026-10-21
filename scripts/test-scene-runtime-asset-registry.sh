#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /private/tmp/gw-scene-runtime-registry-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentTypes.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneRuntimeAssetRegistry.swift" \
  "$ROOT/Tests/SceneWallpaper/SceneRuntimeAssetRegistryTests.swift" \
  -o "$WORK/probe"
"$WORK/probe" "${1:-$WORK/report.json}"
