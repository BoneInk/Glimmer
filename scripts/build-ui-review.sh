#!/bin/bash
# Isolated native UI review bundle. Does not launch or replace the production app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${GW_UI_REVIEW_OUT:-$ROOT/evidence/ui-review-build}"
APP="$OUT/GlimmerReview.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer" -name '*.swift' ! -name 'AppMain.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -D GW_UI_REVIEW -O -whole-module-optimization \
  -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreGraphics \
  -o "$APP/Contents/MacOS/GlimmerReview" \
  "${SOURCES[@]}" "$ROOT/Tests/UIReview/UIReviewMain.swift" "$ROOT/Tests/UIReview/WorkshopRingReviewView.swift"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>GlimmerReview</string>
<key>CFBundleDisplayName</key><string>Glimmer · 界面验证</string>
<key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.review</string>
<key>CFBundleExecutable</key><string>GlimmerReview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.14.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict></plist>
PLIST
if [ -f "$ROOT/evidence/ui-test-video.mp4" ]; then
  cp "$ROOT/evidence/ui-test-video.mp4" "$APP/Contents/Resources/ui-test-video.mp4"
fi
rm -rf "$APP/Contents/Resources/WebAuthorWallpaper"
cp -R "$ROOT/Tests/Fixtures/WebAuthorWallpaper" "$APP/Contents/Resources/WebAuthorWallpaper"
rm -rf "$APP/Contents/Resources/SceneImageWallpaper"
cp -R "$ROOT/Tests/Fixtures/SceneImageWallpaper" "$APP/Contents/Resources/SceneImageWallpaper"
rm -rf "$APP/Contents/Resources/SceneScriptWallpaper"
cp -R "$ROOT/Tests/Fixtures/SceneScriptWallpaper" "$APP/Contents/Resources/SceneScriptWallpaper"
rm -rf "$APP/Contents/Resources/SceneModuleWallpaper"
cp -R "$ROOT/Tests/Fixtures/SceneModuleWallpaper" "$APP/Contents/Resources/SceneModuleWallpaper"
rm -rf "$APP/Contents/Resources/SceneHierarchyWallpaper"
cp -R "$ROOT/Tests/Fixtures/SceneHierarchyWallpaper" "$APP/Contents/Resources/SceneHierarchyWallpaper"
cp "$ROOT/NOTICE.md" "$APP/Contents/Resources/NOTICE.md"
if [ -f "$ROOT/Sources/Glimmer/SceneWallpaper/ThirdParty/RePKG-LICENSE.txt" ]; then
  cp "$ROOT/Sources/Glimmer/SceneWallpaper/ThirdParty/RePKG-LICENSE.txt" "$APP/Contents/Resources/RePKG-LICENSE.txt"
fi
codesign --force --deep --sign - --timestamp=none "$APP"
GW_SCENE_WORKER_OUT="$OUT/SceneScriptWorker" bash "$ROOT/scripts/build-scene-script-worker.sh"
mkdir -p "$APP/Contents/Helpers"
cp "$OUT/SceneScriptWorker/GlimmerSceneScriptWorker" "$APP/Contents/Helpers/GlimmerSceneScriptWorker"
cp "$ROOT/Workers/SceneScript/ThirdParty/Acorn/LICENSE" "$APP/Contents/Resources/Acorn-LICENSE.txt"
for module_notice in eslint-scope esrecurse estraverse; do
  cp "$ROOT/Workers/SceneScript/ThirdParty/ModuleScope/$module_notice/LICENSE" "$APP/Contents/Resources/ModuleScope-$module_notice-LICENSE.txt"
done
codesign --force --sign - --timestamp=none "$APP"
printf 'Review app: %s\nLaunch: open -n "%s"\n' "$APP" "$APP"
