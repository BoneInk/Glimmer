#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glimmer-resource-streaming.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer/WebWallpaper" -name '*.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
  "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
  "$ROOT/Tests/WebWallpaperRuntime/LocalWallpaperFileResourceTests.swift" -framework AppKit -framework WebKit -o "$WORK/probe"
"$WORK/probe"
