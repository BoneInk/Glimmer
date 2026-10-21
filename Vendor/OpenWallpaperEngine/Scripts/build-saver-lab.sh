#!/bin/zsh
# Builds the live screen saver's Phase 0 lab (docs/screen-saver.md, "Live screen saver lab"):
#
#   <out>/OWE Live Lab.saver             the legacy saver, bundle id app.openwallpaperengine.saver.lab,
#                                        principal class OWELiveLabSaverView, logging under
#                                        app.openwallpaper.engine.saverlab
#   <out>/Open Wallpaper Engine.app      a Debug build of the app with the screen saver extension
#                                        (Contents/PlugIns/OpenWallpaperEngineSaverExtension.appex, lab
#                                        logging) and the broker (Contents/Helpers/owe-saver-broker)
#   <out>/app.openwallpaperengine.saver-broker.plist
#                                        a launchd agent for that broker, for `launchctl bootstrap`
#
# It installs, registers and selects nothing: the user does that (the doc's steps). The extension
# is put into a copy of the app outside the build folder, so building never registers it with
# LaunchServices or pluginkit.
#
# Usage: Scripts/build-saver-lab.sh [<out folder>] [<derived data folder>]
set -euo pipefail

root=${0:A:h:h}
out=${1:-$root/build/saver-lab}
dd=${2:-$root/build/saver-lab-dd}
mkdir -p "$out" "$dd"

lab_settings=(
    OWE_SAVER_CONDITIONS=OWE_SAVER_LAB
    SYMROOT="$dd/targets/Products" OBJROOT="$dd/targets/Intermediates"
)

echo "== The lab saver"
xcodebuild -project "$root/OpenWallpaperEngine.xcodeproj" -target OpenWallpaperEngineSaver -configuration Debug \
    "${lab_settings[@]}" OWE_SAVER_PRINCIPAL_CLASS=OWELiveLabSaverView PRODUCT_NAME="OWE Live Lab" \
    PRODUCT_MODULE_NAME=OWELiveLabSaver PRODUCT_BUNDLE_IDENTIFIER=app.openwallpaperengine.saver.lab \
    INFOPLIST_KEY_CFBundleDisplayName="OWE Live Lab" -jobs 4 build

echo "== The screen saver extension and the broker"
xcodebuild -project "$root/OpenWallpaperEngine.xcodeproj" -target OpenWallpaperEngineSaverExtension -target OWESaverBroker \
    -configuration Debug "${lab_settings[@]}" OWE_SAVER_DISPLAY_NAME="OWE Live Lab (extension)" -jobs 4 build

echo "== The app"
xcodebuild -project "$root/OpenWallpaperEngine.xcodeproj" -scheme OpenWallpaperEngine -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$dd" -jobs 4 build

products="$dd/targets/Products/Debug"
app="$out/Open Wallpaper Engine.app"
rm -rf "$app" "$out/OWE Live Lab.saver"
ditto "$dd/Build/Products/Debug/Open Wallpaper Engine.app" "$app"
ditto "$products/OWE Live Lab.saver" "$out/OWE Live Lab.saver"
mkdir -p "$app/Contents/PlugIns" "$app/Contents/Helpers"
ditto "$products/OpenWallpaperEngineSaverExtension.appex" "$app/Contents/PlugIns/OpenWallpaperEngineSaverExtension.appex"
ditto "$products/owe-saver-broker" "$app/Contents/Helpers/owe-saver-broker"

# The app's signature covers its nested code: sign it again with the identity it was built with,
# keeping its entitlements, flags and requirements.
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Apple Development.*\)$/\1/p' | head -1)
codesign --force --sign "${identity:--}" --preserve-metadata=entitlements,requirements,flags,runtime --timestamp=none "$app"

broker="$app/Contents/Helpers/owe-saver-broker"
cat > "$out/app.openwallpaperengine.saver-broker.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>app.openwallpaperengine.saver-broker</string>
	<key>Program</key>
	<string>$broker</string>
	<key>MachServices</key>
	<dict>
		<key>C33D7BSFGS.app.openwallpaperengine.saver-broker</key>
		<true/>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST

echo "== Signatures"
codesign --verify --deep --strict "$app" && echo "app: valid"
codesign --verify --strict "$out/OWE Live Lab.saver" && echo "lab saver: valid"
codesign -d --entitlements - "$app/Contents/PlugIns/OpenWallpaperEngineSaverExtension.appex" 2>/dev/null
echo "Built in $out"
