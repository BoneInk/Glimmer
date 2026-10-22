#!/bin/bash
# Separate compositor receiver for visual checks of the production diagnostic.
# Arguments: producer bundle, isolated fixture directory, output app, report JSON.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 4 ]] || { echo 'Usage: build-web-layer-receiver.sh PRODUCER_BUNDLE FIXTURE_DIRECTORY OUTPUT_APP REPORT_JSON' >&2; exit 2; }
PRODUCER="$1/Contents/MacOS/GlimmerWallpaperExtension"
FIXTURE="$2"
APP="$3"
REPORT="$4"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
WORK="$(mktemp -d /tmp/glimmer-layer-receiver-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
SOURCE="$ROOT/Tests/WebWallpaperRuntime/NativeWebLayerReceiver"
clang -fobjc-arc -target arm64-apple-macos26.0 -isysroot "$SDK" -c "$SOURCE.m" -o "$WORK/private.o"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -sdk "$SDK" \
  -parse-as-library -import-objc-header "$SOURCE.h" "$SOURCE.swift" "$WORK/private.o" \
  -framework AppKit -framework WebKit -framework QuartzCore -o "$APP/Contents/MacOS/WebLayerReceiver"
python3 - "$APP" "$PRODUCER" "$FIXTURE" "$REPORT" <<'PY'
import pathlib,plistlib,json,sys
app,producer,fixture,report=map(pathlib.Path,sys.argv[1:])
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(
 CFBundleIdentifier='com.boneinkzhong.glimmer.web-layer-receiver',CFBundleName='Glimmer Web Layer Receiver',
 CFBundleExecutable='WebLayerReceiver',CFBundlePackageType='APPL',CFBundleVersion='1',
 NSHighResolutionCapable=True,LSMinimumSystemVersion='26.0')))
(app/'Contents/Resources/Probe.json').write_text(json.dumps(dict(project=str(fixture.resolve()),producer=str(producer.resolve()),report=str(report.resolve()))))
report.parent.mkdir(parents=True,exist_ok=True)
report.with_suffix('.stderr').touch()
PY
. "$ROOT/scripts/signing-identity.sh"
codesign --force --sign "$(gw_resolve_signing_identity)" "$APP"
codesign --verify --strict "$APP"
printf 'Built native layer receiver: %s\n' "$APP"
