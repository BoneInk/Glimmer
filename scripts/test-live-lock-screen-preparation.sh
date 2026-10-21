#!/bin/bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILT_APP="${GW_CONFIGURED_EXPORT_APP:-$ROOT/build/live-lock-screen/Glimmer.app}"
[[ -f "$BUILT_APP/Contents/MacOS/Glimmer" ]] || { echo 'Build the full app before running this live preparation test.' >&2; exit 1; }
WORK="$(mktemp -d /tmp/glimmer-live-preparation.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Glimmer.app"
ditto "$BUILT_APP" "$APP"
SOURCE_ROOT="${GW_SWIFT_SOURCES_ROOT:-$ROOT/Sources}"
SOURCES=()
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$SOURCE_ROOT/Glimmer" -name '*.swift' ! -name AppMain.swift | sort)
while IFS= read -r path; do SOURCES+=("$path"); done < <(find "$SOURCE_ROOT/SceneBackendShared" -name '*.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -whole-module-optimization -D GW_UNIVERSAL_SCENE_BACKEND -D GW_UI_REVIEW -target arm64-apple-macos26.0 \
 "${SOURCES[@]}" "$ROOT/Tests/LiveLockScreenPreparationTests.swift" -o "$APP/Contents/MacOS/Glimmer"
source "$ROOT/scripts/signing-identity.sh"
codesign --force --sign "$(gw_resolve_signing_identity)" --timestamp=none "$APP"
ASSET_PROFILE="${GW_SCENE_EXPORT_ASSET_PROFILE:-$HOME/Library/Application Support/Glimmer}"
if [[ ! -f "$ASSET_PROFILE/SceneBackend/active-receipt.json" && -z "${GW_SCENE_EXPORT_ASSET_PROFILE:-}" ]]; then
 ASSET_PROFILE="$HOME/Library/Application Support/GlassWallpaper"
fi
GW_SCENE_EXPORT_ASSET_PROFILE="$ASSET_PROFILE" "$APP/Contents/MacOS/Glimmer" "${GW_LIVE_PROBE_FIXTURES:?Set GW_LIVE_PROBE_FIXTURES to the isolated sandbox fixture root}" "$ROOT/build"
