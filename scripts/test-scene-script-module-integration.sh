#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-module-desktop.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
APP="$TEST_OUT/SceneScriptModuleProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$ROOT/evidence/scene-script-module-integration"
cp "$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.scene-script-module-probe</string><key>CFBundleExecutable</key><string>SceneScriptModuleProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
SOURCES=()
for directory in Steam Store Model Import Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
source "$ROOT/scripts/author-web-core-sources.sh"
swiftc "${AUTHOR_WEB_CORE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/WorkshopWallpaperApplication.swift" \
  "$ROOT/Sources/Glimmer/Support/ManagedWallpaperDeletionService.swift" \
  "$ROOT/Tests/SceneWallpaper/SceneScriptModuleIntegrationTests.swift" -o "$APP/Contents/MacOS/SceneScriptModuleProbe"
codesign --force --sign - --timestamp=none "$APP"
"$APP/Contents/MacOS/SceneScriptModuleProbe" "$ROOT/Tests/Fixtures/SceneModuleWallpaper" | tee "$ROOT/evidence/scene-script-module-integration/probe.txt"
