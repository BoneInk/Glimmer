#!/bin/bash
# Embed Sparkle for both full and local builds, preserving framework symlinks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:?Usage: embed-app-updater.sh APP.app [--developer-id]}"
SIGN_OPTIONS=(--timestamp=none)
if [ "${2:-}" = "--developer-id" ]; then
  SIGN_OPTIONS=(--options runtime --timestamp)
elif [ $# -ne 1 ]; then
  echo 'Usage: embed-app-updater.sh APP.app [--developer-id]' >&2
  exit 2
fi
. "$ROOT/scripts/signing-identity.sh"
IDENTITY="$(gw_resolve_signing_identity)"
SOURCE="$ROOT/Vendor/OpenWallpaperEngine/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ ! -d "$FRAMEWORK" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SOURCE" "$FRAMEWORK"
fi
# Sign from the inside out. Keep Sparkle's required helper entitlements.
for component in \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK"; do
  codesign --force --preserve-metadata=entitlements "${SIGN_OPTIONS[@]}" --sign "$IDENTITY" "$component"
done
codesign --verify --deep --strict "$FRAMEWORK"
cp "$ROOT/Vendor/OpenWallpaperEngine/Vendor/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
