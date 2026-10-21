#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glimmer-wallpaper-backdrop.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
WEB_SOURCES=()
while IFS= read -r source; do WEB_SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer/WebWallpaper" -name '*.swift' | sort)
swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path "$WORK/module-cache" -parse-as-library \
  "${WEB_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
  "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Tests/wallpaper-backdrop/BackdropDependencyStubs.swift" \
  "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
  "$ROOT/Sources/Glimmer/UI/WindowGlassBackdrop.swift" \
  "$ROOT/Sources/Glimmer/UI/WallpaperWorkspaceBackdrop.swift" \
  "$ROOT/Tests/wallpaper-backdrop/BackdropProbe.swift" -o "$WORK/probe"
"$WORK/probe"
