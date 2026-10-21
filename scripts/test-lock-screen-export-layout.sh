#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-lock-export-layout.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
 "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSettings.swift" \
 "$ROOT/Sources/Glimmer/Policies/GWModuleSupport.swift" \
 "$ROOT/Sources/Glimmer/Policies/GWPolicyModels.swift" \
 "$ROOT/Sources/Glimmer/Playlist/GWPlaylistModels.swift" \
 "$ROOT/Sources/Glimmer/Settings/GWSettingsModels.swift" \
 "$ROOT/Sources/Glimmer/Settings/GWSettingsCoordinator.swift" \
 "$ROOT/Sources/Glimmer/Settings/GWConfigurationTransfer.swift" \
 "$ROOT/Sources/Glimmer/UI/GlassStyle.swift" \
 "$ROOT/Sources/Glimmer/UI/WindowGlassBackdrop.swift" \
 "$ROOT/Sources/Glimmer/UI/Policies/GWPolicyUISupport.swift" \
 "$ROOT/Sources/Glimmer/UI/Settings/GWSettingsSupport.swift" \
 "$ROOT/Sources/Glimmer/UI/Settings/LockScreenExportSettingsSection.swift" \
 "$ROOT/Tests/LockScreenExportSettingsLayoutTests.swift" -o "$WORK/probe"
"$WORK/probe"
