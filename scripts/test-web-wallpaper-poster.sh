#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glass-web-poster.XXXXXX)"
APP="$WORK/WebPosterProbe.app"
mkdir -p "$APP/Contents/MacOS" "$WORK/project" "$ROOT/evidence/web-backdrop"
printf '{"type":"web","file":"index.html","preview":"preview.png"}' > "$WORK/project/project.json"
printf '<!doctype html><html><body style="margin:0;background:rgb(255,0,0)"></body></html>' > "$WORK/project/index.html"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
WEB_SOURCES=()
while IFS= read -r source; do WEB_SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer/WebWallpaper" -name '*.swift' | sort)
swiftc -swift-version 6 -target arm64-apple-macos26.0 -module-cache-path "$WORK/module-cache" -parse-as-library \
  "${WEB_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
  "$ROOT/Sources/Glimmer/AuthorPropertyAssets/AuthorPropertyAssetTypes.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Media/VideoProbe.swift" \
  "$ROOT/Tests/wallpaper-backdrop/BackdropDependencyStubs.swift" \
  "$ROOT/Sources/Glimmer/Support/GlassState.swift" \
  "$ROOT/Sources/Glimmer/UI/WindowGlassBackdrop.swift" \
  "$ROOT/Sources/Glimmer/UI/WallpaperWorkspaceBackdrop.swift" \
  "$ROOT/Tests/wallpaper-backdrop/WebPosterProbe.swift" -o "$APP/Contents/MacOS/WebPosterProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.web-poster-probe</string><key>CFBundleExecutable</key><string>WebPosterProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "${GW_POSTER_BUILD_ONLY:-0}" == "1" ]]; then
  printf 'PASS: real WebKit poster probe compiled (GUI not launched)\n'
  exit 0
fi
REPORT="probe.json"
if [[ "${GW_POSTER_NATIVE_VISIBILITY:-0}" == "1" ]]; then REPORT="native-visibility-probe.json"; fi
"$APP/Contents/MacOS/WebPosterProbe" "$WORK/project" "$ROOT/evidence/web-backdrop/$REPORT"
