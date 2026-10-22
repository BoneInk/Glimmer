#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${GW_INFORMATION_REVIEW_OUT:-$ROOT/evidence/20261021-workshop-authors/ui-review}"
APP="$OUT/GlimmerInformationReview.app"
mkdir -p "$APP/Contents/MacOS"
SOURCES=()
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/Glimmer" -name '*.swift' ! -name AppMain.swift | sort)
while IFS= read -r source; do SOURCES+=("$source"); done < <(find "$ROOT/Sources/SceneBackendShared" -name '*.swift' | sort)
swiftc -swift-version 6 -strict-concurrency=complete -D GW_UI_REVIEW -D GW_UNIVERSAL_SCENE_BACKEND -O -whole-module-optimization \
 -target arm64-apple-macos26.0 "${SOURCES[@]}" "$ROOT/Tests/WorkshopInformationUIReview.swift" -o "$APP/Contents/MacOS/Review"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.information-review</string><key>CFBundleName</key><string>GlimmerInformationReview</string><key>CFBundleExecutable</key><string>Review</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
source "$ROOT/scripts/signing-identity.sh"
codesign --force --timestamp=none --sign "$(gw_resolve_signing_identity)" "$APP"
echo "$APP"
