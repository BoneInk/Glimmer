#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-configuration-compatibility-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export TMPDIR=/private/tmp/glimmer-tmp
export CLANG_MODULE_CACHE_PATH=/private/tmp/glimmer-clang-module-cache
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH" /private/tmp/glimmer-swift-module-cache

swiftc -disable-sandbox \
  -module-cache-path /private/tmp/glimmer-swift-module-cache \
  -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWModuleSupport.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWPolicyModels.swift" \
  "$ROOT/Sources/Glimmer/Playlist/GWPlaylistModels.swift" \
  "$ROOT/Sources/Glimmer/LockScreen/LockScreenExportSettings.swift" \
  "$ROOT/Sources/Glimmer/Settings/GWSettingsModels.swift" \
  "$ROOT/Sources/Glimmer/Settings/GWConfigurationTransfer.swift" \
  "$ROOT/Tests/GlimmerConfigurationCompatibilityTests.swift" \
  -o "$WORK/GlimmerConfigurationCompatibilityTests"

"$WORK/GlimmerConfigurationCompatibilityTests"
