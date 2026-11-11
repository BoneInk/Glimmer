#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-web-desktop.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/author-web-core-sources.sh"
SOURCES=()
for directory in Model Store Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
APP="$WORK/WebDesktopProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp -R "$ROOT/Tests/Fixtures/WebAuthorWallpaper" "$WORK/project"
python3 - "$WORK/project" <<'PY'
import math, struct, sys, wave
from pathlib import Path
root = Path(sys.argv[1])
with wave.open(str(root / 'tone.wav'), 'wb') as output:
    output.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
    output.writeframes(b''.join(struct.pack('<h', int(300 * math.sin(i * 2 * math.pi * 440 / 8000))) for i in range(8000)))
with (root / 'index.html').open('a') as output:
    output.write("<script>window.testAudio=new Audio('tone.wav');testAudio.loop=true;window.audioResult='pending';testAudio.play().then(()=>audioResult='played').catch(e=>audioResult=e.name);</script>")
PY
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" "${AUTHOR_WEB_CORE_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Tests/WebDesktopIntegrationTests.swift" -o "$APP/Contents/MacOS/WebDesktopProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.web-desktop-probe</string><key>CFBundleExecutable</key><string>WebDesktopProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/WebDesktopProbe" "$WORK/project"
