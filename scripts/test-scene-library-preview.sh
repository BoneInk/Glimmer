#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-library-preview.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/author-web-core-sources.sh"
SOURCES=()
for directory in Model Store Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
mkdir -p "$ROOT/evidence/scene-wallpaper-ap05"
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -parse-as-library \
 "${SOURCES[@]}" "${AUTHOR_WEB_CORE_SOURCES[@]}" \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
 "$ROOT/Sources/Glimmer/UI/AuthorProperties/AuthorPropertyEditingCapabilities.swift" \
 "$ROOT/Sources/Glimmer/UI/AuthorProperties/AuthorPropertySettingsSession.swift" \
 "$ROOT/Sources/Glimmer/UI/AuthorProperties/AuthorPropertySettingsSummary.swift" \
 "$ROOT/Sources/Glimmer/UI/SceneWallpaperPresentation.swift" \
 "$ROOT/Sources/Glimmer/UI/SceneDetailInteractionState.swift" \
 "$ROOT/Sources/Glimmer/UI/SceneWallpaperPreviewView.swift" \
 "$ROOT/Tests/SceneWallpaper/SceneLibraryPreviewProbe.swift" \
 -framework AppKit -framework SwiftUI -framework AVFoundation -o "$WORK/probe"
"$WORK/probe" "$ROOT/Tests/Fixtures/SceneImageWallpaper" "$ROOT/evidence/scene-wallpaper-ap05/library-preview-probe.json"
