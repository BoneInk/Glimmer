#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-author-services.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/author-web-core-sources.sh"
SOURCES=()
for directory in Model Store Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
APP="$WORK/AuthorServicesProbe.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" "${AUTHOR_WEB_CORE_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Tests/AuthorPropertyServicesIntegrationTests.swift" -o "$APP/Contents/MacOS/AuthorServicesProbe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.author-services-probe</string><key>CFBundleExecutable</key><string>AuthorServicesProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/AuthorServicesProbe" "${1:-$ROOT/evidence/author-property-services-integration.json}"
