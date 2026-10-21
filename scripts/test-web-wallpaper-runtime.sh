#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
OUT="${GW_WEB_RUNTIME_EVIDENCE:-$ROOT/evidence/web-wallpaper-runtime}"
mkdir -p "$OUT"
WORK="$(mktemp -d /tmp/glass-web-runtime.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/GlimmerWebRuntimeProbe.app"
mkdir -p "$APP/Contents/MacOS" "$WORK/project"
cp "$ROOT/Tests/WebWallpaperRuntime/Fixtures/"* "$WORK/project/"
python3 - "$WORK/project/tone.wav" <<'PYMEDIA'
import math,struct,sys,wave
with wave.open(sys.argv[1], 'wb') as output:
    output.setparams((1,2,8000,0,'NONE','not compressed'))
    output.writeframes(b''.join(struct.pack('<h',int(3000*math.sin(i*2*math.pi*440/8000))) for i in range(8000)))
PYMEDIA
printf 'SECRET_OUTSIDE_PROJECT_DO_NOT_READ' > "$WORK/secret.txt"
ln -s "$WORK/secret.txt" "$WORK/project/outside.txt"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer/WebWallpaper" -name '*.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
 "${SOURCES[@]}" "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetStore.swift" "$ROOT/Tests/WebWallpaperRuntime/WebWallpaperRuntimeProbe.swift" \
 -framework AppKit -framework WebKit -framework AVFoundation -o "$APP/Contents/MacOS/GlimmerWebRuntimeProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.web-runtime-probe</string><key>CFBundleExecutable</key><string>GlimmerWebRuntimeProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/GlimmerWebRuntimeProbe" "$WORK/project" "$OUT/probe.json"
