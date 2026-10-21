#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/signing-identity.sh"
SIGN_IDENTITY="$(gw_resolve_signing_identity)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
# LaunchServices opens an Intel-only application to present Apple's official Rosetta prompt.
# Keep the helper Intel-only even though the main application is arm64.
echo "== 构建 Rosetta 官方安装引导组件 =="
ROSETTA_HELPER="$1"
mkdir -p "$ROSETTA_HELPER/Contents/MacOS"
xcrun clang -target x86_64-apple-macos11.0 -isysroot "$SDK" \
  "$ROOT/Resources/RosettaLauncher/main.c" \
  -o "$ROSETTA_HELPER/Contents/MacOS/RosettaLauncher"
cat > "$ROSETTA_HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>RosettaLauncher</string>
<key>CFBundleDisplayName</key><string>Glimmer Rosetta 安装引导</string>
<key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.rosetta-launcher</string>
<key>CFBundleExecutable</key><string>RosettaLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$ROSETTA_HELPER"

