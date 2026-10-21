#!/bin/bash
# Embed the self-contained, replaceable SteamKit2 helper and matching notices.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/signing-identity.sh"
SIGN_IDENTITY="$(gw_resolve_signing_identity)"
APP="${1:?Usage: embed-steam-content-helper.sh path/to/App.app}"
PUBLISHED="${GW_OUT_DIR:-$ROOT/build}/SteamContent"
DEST="$APP/Contents/Resources/SteamContentRuntime"
LAUNCHER="$APP/Contents/Helpers/SteamContent"
SOURCE_ARCHIVE="$ROOT/.tools/steamkit-source-3.4.0.tar.gz"
test -x "$PUBLISHED/GlimmerSteamContent"
test -f "$PUBLISHED/SteamKit2.dll"
test -f "$SOURCE_ARCHIVE"
test "$(shasum -a 256 "$SOURCE_ARCHIVE" | cut -d ' ' -f 1)" = "7477a815ff0ca7e385f84071abf3ac9aa7dd9a6b9d324331c8b17f4a56c87115"
mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/SteamContent"
rm -rf "$DEST"
rm -rf "$LAUNCHER"
mkdir -p "$LAUNCHER"
ditto "$PUBLISHED" "$DEST"
find "$DEST" -name '*.pdb' -delete
# .NET's apphost resolves its managed DLL and runtime beside the executable.
# Preserve that layout and sign all native runtime components individually.
while IFS= read -r -d '' native; do
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$native"
done < <(find "$DEST" -type f -name '*.dylib' -print0)
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DEST/GlimmerSteamContent"
DEVELOPER_DIR=/Library/Developer/CommandLineTools /usr/bin/clang -arch arm64 -Wall -Wextra -Werror \
  "$ROOT/Workers/SteamContent/BundleLauncher.c" -o "$LAUNCHER/GlimmerSteamContent"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$LAUNCHER/GlimmerSteamContent"
cp "$SOURCE_ARCHIVE" "$APP/Contents/Resources/SteamContent/SteamKit2-3.4.0-source.tar.gz"
cp "$ROOT/Workers/SteamContent/SteamKit2-LICENSE.txt" "$APP/Contents/Resources/SteamContent/"
cp "$ROOT/Workers/SteamContent/SteamKit2-THIRD-PARTY.txt" "$APP/Contents/Resources/SteamContent/"
cp -R "$ROOT/Workers/SteamContent/Notices" "$APP/Contents/Resources/SteamContent/"
cp "$ROOT/Workers/SteamContent/packages.lock.json" "$APP/Contents/Resources/SteamContent/"
codesign --verify --strict "$DEST/GlimmerSteamContent"
