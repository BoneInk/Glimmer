#!/bin/bash
# Produce a signed ZIP and signed appcast. Never uploads or edits the live feed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${APP_PATH:-${GW_OUT_DIR:-$ROOT/build}/Glimmer.app}"
OUT="${OUTPUT_DIR:-$ROOT/dist}"
KEY="${GLIMMER_UPDATE_KEY_FILE:-$ROOT/.tools/glimmer-updates.ed25519.key}"
TAG=""
NOTES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app|--out|--key|--tag|--notes)
      [ $# -ge 2 ] || { echo "$1 needs a value" >&2; exit 2; }
      case "$1" in
        --app) APP="$2" ;; --out) OUT="$2" ;; --key) KEY="$2" ;;
        --tag) TAG="$2" ;; --notes) NOTES="$2" ;;
      esac
      shift 2 ;;
    -h|--help)
      echo 'Usage: package-update.sh [--app Glimmer.app] [--out dist] [--key private.ed25519.key] [--tag v1.0.0] [--notes notes.txt]'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
die() { echo "$*" >&2; exit 1; }
[ -f "$APP/Contents/Info.plist" ] || die "App not found: $APP"
[ -f "$KEY" ] || die "Update signing key not found. See docs/auto-updates.md."
[ -z "$NOTES" ] || [ -f "$NOTES" ] || die "Release notes not found: $NOTES"
codesign --verify --deep --strict "$APP"
PUBLIC="$(xcrun swift "$ROOT/scripts/update-signing.swift" public "$KEY")"
python3 - "$APP" "$PUBLIC" "$KEY" <<'PY'
import plistlib, re, sys
from pathlib import Path
from urllib.parse import urlsplit
app = Path(sys.argv[1]).resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'com.boneinkzhong.glimmer', 'Unexpected app identity'
assert info['SUPublicEDKey'] == sys.argv[2], 'Signing key does not match the public key embedded in the app'
assert info.get('SURequireSignedFeed') and info.get('SUVerifyUpdateBeforeExtraction'), 'Signed feed and archive verification must be enabled'
assert urlsplit(info['SUFeedURL']).scheme == 'https', 'Production feed must use HTTPS'
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', info['CFBundleVersion']), 'Invalid build number'
assert re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', info['CFBundleShortVersionString']), 'Invalid version'
assert not Path(sys.argv[3]).resolve().is_relative_to(app), 'Private key must not be inside the app'
PY
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EXE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXE")"
case "$ARCHS" in
  *arm64*x86_64*|*x86_64*arm64*) ARCH=universal ;;
  *arm64*) ARCH=arm64 ;;
  *) die "Unsupported architecture: $ARCHS" ;;
esac
TAG="${TAG:-v$VERSION}"
[[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid release tag"
NAME="Glimmer-$VERSION-$ARCH.zip"
mkdir -p "$OUT"
[ ! -e "$OUT/$NAME" ] || die "Archive already exists: $OUT/$NAME (use a new output directory)"
WORK="$(mktemp -d "$OUT/.update.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$(bash "$ROOT/scripts/fetch-sparkle-tools.sh")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/$NAME"
if [ -n "$NOTES" ]; then
  cp "$NOTES" "$WORK/${NAME%.zip}.txt"
fi
"$BIN/generate_appcast" --ed-key-file "$KEY" --maximum-deltas 0 \
  --embed-release-notes --download-url-prefix "https://github.com/BoneInk/Glimmer/releases/download/$TAG/" \
  -o "$WORK/appcast.xml" "$WORK"
"$BIN/sign_update" --ed-key-file "$KEY" --verify "$WORK/appcast.xml"
python3 - "$WORK/appcast.xml" "$BUILD" "$NAME" "$TAG" <<'PY'
import sys, xml.etree.ElementTree as ET
s = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(sys.argv[1]).findall('./channel/item')
assert len(items) == 1, 'Expected one complete update archive'
item = items[0]
assert item.findtext(s + 'version') == sys.argv[2], 'Wrong build in appcast'
enclosure = item.find('enclosure')
assert enclosure.get('url') == f'https://github.com/BoneInk/Glimmer/releases/download/{sys.argv[4]}/{sys.argv[3]}'
assert enclosure.get(s + 'edSignature') and int(enclosure.get('length')) > 0, 'Missing archive signature'
PY
mv "$WORK/$NAME" "$OUT/$NAME"
mv "$WORK/appcast.xml" "$OUT/appcast.xml"
(cd "$OUT" && shasum -a 256 "$NAME" > "$NAME.sha256")
printf 'Update archive: %s/%s\nSigned feed: %s/appcast.xml\n' "$OUT" "$NAME" "$OUT"
echo 'Publish the archive to its GitHub release first, then publish appcast.xml to main. See docs/auto-updates.md.'
