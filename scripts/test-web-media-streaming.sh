#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="${1:?Pass the project.json path for the read-only real-wallpaper probe}"
OUT="${GW_WEB_MEDIA_EVIDENCE:-$ROOT/evidence/web-media-streaming}"
WORK="$(mktemp -d /tmp/glimmer-web-media.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/GlimmerWebMediaProbe.app"
mkdir -p "$APP/Contents/MacOS" "$OUT"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer/WebWallpaper" -name '*.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 -parse-as-library \
  "${SOURCES[@]}" "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
  "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
  "$ROOT/Tests/WebWallpaperRuntime/WebMediaStreamingProbe.swift" \
  -framework AppKit -framework WebKit -o "$APP/Contents/MacOS/GlimmerWebMediaProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.web-media-probe</string><key>CFBundleExecutable</key><string>GlimmerWebMediaProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/GlimmerWebMediaProbe" "$PROJECT" "$OUT/probe.json"
python3 - "$OUT/probe.json" <<'PY'
import json,sys
assert json.load(open(sys.argv[1]))['success'], 'Real wallpaper media probe failed'
PY
