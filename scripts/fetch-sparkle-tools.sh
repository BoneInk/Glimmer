#!/bin/bash
# Official tools matching the vendored framework. No keys are read or created.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="2.10.0"
SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
DEST="${1:-$ROOT/.tools/sparkle-$VERSION}"
FRAMEWORK="$ROOT/Vendor/OpenWallpaperEngine/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
LINKED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FRAMEWORK/Resources/Info.plist")"
if [ "$LINKED" != "$VERSION" ]; then
  echo "Sparkle version changed; update the pinned tools version and SHA-256." >&2
  exit 1
fi
mkdir -p "$DEST"
ARCHIVE="$DEST/Sparkle-$VERSION.tar.xz"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --retry 3 --connect-timeout 20 --max-time 300 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" \
    -o "$ARCHIVE.download" >&2
  mv "$ARCHIVE.download" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA256" "$ARCHIVE" | shasum -a 256 -c - >&2
# Re-extract from the verified archive rather than trusting cached executables.
tar -xf "$ARCHIVE" -C "$DEST" ./bin
test -x "$DEST/bin/generate_keys"
test -x "$DEST/bin/sign_update"
test -x "$DEST/bin/generate_appcast"
printf '%s\n' "$DEST/bin"
