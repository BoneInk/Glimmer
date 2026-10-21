#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-scene-lock-cache.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift" \
 "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
 "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift" \
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
 "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyOverrideStore.swift" \
 "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenStoreTransaction.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSettings.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenVideoTranscoder.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/ExperimentalLockScreenAssets.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LiveWallpaperBundle.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/RenderedLockScreenVideoCache.swift" \
 "$ROOT/Tests/SceneLockScreenCacheTests.swift" -o "$WORK/probe"
"$WORK/probe"
