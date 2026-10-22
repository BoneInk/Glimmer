#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-web-lock-export.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
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
 "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyOverrideStore.swift" \
 "$ROOT/Sources/Glimmer/Support/WebWallpaperLockScreenConfiguration.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperConfiguration.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperResourceSnapshot.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperResourceBridge.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperBridge.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/LocalWallpaperSchemeHandler.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/LocalWallpaperFileResource.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebMVP9Container.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperMediaResolver.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperRuntime.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperFramePacer.swift" \
 "$ROOT/Sources/Glimmer/WebWallpaper/WebWallpaperMutedMediaPolicy.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenStoreTransaction.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSettings.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenVideoTranscoder.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSourceResolver.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/ExperimentalLockScreenAssets.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LiveWallpaperBundle.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/WebWallpaperLockScreenExporter.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/RenderedLockScreenVideoCache.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/WebWallpaperLockScreenVideoCache.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/ExperimentalLockScreenCoordinator.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LiveWallpaperPreparer.swift" \
 "$ROOT/Tests/WebLockScreenExportTests.swift" -o "$WORK/probe"
"$WORK/probe"
