#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-runtime-services.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
mkdir -p "$ROOT/evidence/scene-runtime-services"
# Deliberately excludes Desktop/Thumbnail/Importer code while their owners work.
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "$ROOT"/Sources/Glimmer/AuthorProperties/*.swift \
 "$ROOT"/Sources/Glimmer/AuthorPropertyAssets/*.swift \
 "$ROOT"/Sources/Glimmer/WebWallpaper/*.swift \
 "$ROOT"/Sources/Glimmer/SceneWallpaper/*.swift \
 "$ROOT"/Sources/Glimmer/SceneScript/*.swift \
 "$ROOT"/Sources/Glimmer/Model/*.swift \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Support/AuthorPropertyServices.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneRuntimeServicesProbe.swift" \
 -framework AppKit -lcompression -o "$WORK/probe"
"$WORK/probe" "$ROOT/Tests/Fixtures/SceneImageWallpaper" "${1:-$ROOT/evidence/scene-runtime-services/probe.json}"
