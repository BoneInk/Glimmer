#!/bin/bash
# Real signed update -> download -> validation -> temporary app replacement.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-updates-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
FRAMEWORKS="$ROOT/Vendor/OpenWallpaperEngine/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
. "$ROOT/scripts/signing-identity.sh"
export GW_SIGNING_IDENTITY="$(gw_resolve_signing_identity)"
swiftc -swift-version 6 -strict-concurrency=complete \
  "$ROOT/Sources/Glimmer/Updates/GWAppUpdateConfiguration.swift" \
  "$ROOT/Tests/AppUpdates/UpdateConfigurationTests.swift" -o "$WORK/config-tests"
"$WORK/config-tests" "$ROOT"
swiftc -swift-version 6 -strict-concurrency=complete -DDEBUG \
  -F "$FRAMEWORKS" -framework Sparkle \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
  "$ROOT/Sources/Glimmer/Updates/GWAppUpdateConfiguration.swift" \
  "$ROOT/Sources/Glimmer/Updates/GWAppUpdater.swift" \
  "$ROOT/Tests/AppUpdates/UpdateProbeMain.swift" -o "$WORK/UpdateProbe"
BIN="$(bash "$ROOT/scripts/fetch-sparkle-tools.sh")"
python3 "$ROOT/Tests/AppUpdates/run-update-tests.py" "$ROOT" "$WORK" "$BIN"
