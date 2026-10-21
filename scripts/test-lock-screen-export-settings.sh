#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-lock-export-settings.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
SOURCES=(
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift"
 "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift"
 "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift"
 "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift"
 "$ROOT/Sources/Glimmer/Store/AppStorage.swift"
 "$ROOT/Sources/Glimmer/Media/VideoProbe.swift"
 "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift"
 "$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift"
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenStoreTransaction.swift"
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSettings.swift"
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSourceResolver.swift"
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenVideoTranscoder.swift"
 "$ROOT/Sources/Glimmer/LockScreen/ExperimentalLockScreenAssets.swift"
 "$ROOT/Sources/Glimmer/LockScreen/LiveWallpaperBundle.swift"
 "$ROOT/Sources/Glimmer/Policies/GWModuleSupport.swift"
 "$ROOT/Sources/Glimmer/Policies/GWPolicyModels.swift"
 "$ROOT/Sources/Glimmer/Playlist/GWPlaylistModels.swift"
 "$ROOT/Sources/Glimmer/Settings/GWSettingsModels.swift"
 "$ROOT/Sources/Glimmer/Settings/GWConfigurationTransfer.swift"
 "$ROOT/Sources/Glimmer/Settings/GWSettingsCoordinator.swift"
)
for TEST in LockScreenExportSettingsTests GWSettingsFPSPersistenceTests GWSettingsBackgroundPreferencesTests; do
 swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" "$ROOT/Tests/$TEST.swift" -o "$WORK/$TEST"
 "$WORK/$TEST"
done
