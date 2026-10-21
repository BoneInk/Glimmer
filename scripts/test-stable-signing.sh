#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/signing-identity.sh"

IDENTITY="$(gw_resolve_signing_identity)"
if [ "$IDENTITY" = "-" ]; then
  echo "SKIP: no Apple Development identity is available for stable-signing verification"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-signing.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

make_app() {
  local path="$1" version_text="$2" identity="$3"
  mkdir -p "$path/Contents/MacOS"
  cat > "$WORK/main.c" <<C
#include <stdio.h>
int main(void) { puts("$version_text"); return 0; }
C
  xcrun clang "$WORK/main.c" -o "$path/Contents/MacOS/SigningProbe"
  cat > "$path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.signing-probe</string>
<key>CFBundleExecutable</key><string>SigningProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>$version_text</string>
</dict></plist>
PLIST
  codesign --force --sign "$identity" --timestamp=none "$path" >/dev/null
}

make_app "$WORK/stable-a.app" 1 "$IDENTITY"
make_app "$WORK/stable-b.app" 2 "$IDENTITY"
make_app "$WORK/adhoc-a.app" 1 -
make_app "$WORK/adhoc-b.app" 2 -

stable_a="$(codesign -d -r- "$WORK/stable-a.app" 2>&1 | sed -n 's/^designated => //p')"
stable_b="$(codesign -d -r- "$WORK/stable-b.app" 2>&1 | sed -n 's/^designated => //p')"
adhoc_a="$(codesign -d -r- "$WORK/adhoc-a.app" 2>&1 | sed -n 's/^designated => //p')"
adhoc_b="$(codesign -d -r- "$WORK/adhoc-b.app" 2>&1 | sed -n 's/^designated => //p')"

[ -n "$stable_a" ] && [ "$stable_a" = "$stable_b" ]
[ -n "$adhoc_a" ] && [ -n "$adhoc_b" ] && [ "$adhoc_a" != "$adhoc_b" ]
codesign --verify --deep --strict "$WORK/stable-a.app"
codesign --verify --deep --strict "$WORK/stable-b.app"
echo "PASS: the same existing Apple identity produced a stable designated requirement across two code versions; ad-hoc controls differed"
