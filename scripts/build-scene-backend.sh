#!/bin/zsh
set -eu
workspace_root=$(cd "$(dirname "$0")/.." && pwd)
backend_source="$workspace_root/Vendor/OpenWallpaperEngine"
backend_build=${SCENE_BACKEND_BUILD_DIR:-"$workspace_root/evidence/scene-backend-integration"}
# The app itself may use Command Line Tools; this framework requires full Xcode.
# Keep the selection scoped to this child process instead of changing xcode-select.
export DEVELOPER_DIR="${SCENE_BACKEND_DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$backend_build"
source "$workspace_root/scripts/signing-identity.sh"
backend_signing_identity=$(gw_resolve_signing_identity)
if [[ "$backend_signing_identity" == "-" ]]; then
  echo "Scene backend requires the existing stable certificate-backed signing identity." >&2
  exit 2
fi
# Expand only repository-owned local Metal headers; no official assets enter this output.
python3 - "$backend_source/OpenWallpaperEngine" <<'PY'
from pathlib import Path
import sys,re
root=Path(sys.argv[1])
def expand(p):
    text=p.read_text()
    return re.sub(r'^\s*#include\s+"([^\"]+)"\s*$',lambda m:expand(p.parent/m.group(1)),text,flags=re.M)
files=sorted(root.rglob('*.metal'))
(root/'Resources/BackendBuiltins.metal.txt').write_text('\n'.join('// SOURCE '+str(p.relative_to(root))+'\n'+expand(p) for p in files))
PY
xcodebuild -project "$backend_source/OpenWallpaperEngine.xcodeproj" \
  -target OpenWallpaperEngineFramework -configuration Release -sdk macosx -arch arm64 -jobs 6 \
  -clonedSourcePackagesDirPath "$backend_build/packages" -packageCachePath "$backend_build/package-cache" \
  -disablePackageRepositoryCache SYMROOT="$backend_build/products" OBJROOT="$backend_build/objects" \
  CLANG_MODULE_CACHE_PATH="$backend_build/module-cache" COMPILER_INDEX_STORE_ENABLE=NO INDEX_ENABLE_DATA_STORE=NO \
  INDEX_DATA_STORE_DIR="$backend_build/index" SWIFT_INDEX_STORE_PATH="$backend_build/index" \
  'EXCLUDED_SOURCE_FILE_NAMES=*.metal' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=NO build
products="$backend_build/products/Release"
module_maps="$backend_build/objects/GeneratedModuleMaps"
codesign --force --deep --preserve-metadata=entitlements --timestamp=none --sign "$backend_signing_identity" "$products/Sparkle.framework"
codesign --force --timestamp=none --sign "$backend_signing_identity" "$products/OpenWallpaperEngine.framework"
service="$backend_build/SceneBackendHelper.xpc"
mkdir -p "$service/Contents/MacOS" "$service/Contents/Resources"
# Resolve package resources from the helper bundle, never a developer build directory.
for resource_bundle in "$products"/*.bundle; do
  [[ -e "$resource_bundle" ]] && ditto "$resource_bundle" "$service/Contents/Resources/$(basename "$resource_bundle")"
done
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  "$workspace_root/Sources/SceneBackendHelper/main.swift" \
  -F "$products" -I "$products" \
  -Xcc "-fmodule-map-file=$module_maps/ShaderToolchain.modulemap" \
  -Xcc "-fmodule-map-file=$module_maps/CUfbx.modulemap" \
  -framework OpenWallpaperEngine -Xlinker -rpath -Xlinker '@executable_path/../../../../Frameworks' \
  -module-cache-path "$backend_build/helper-module-cache" -o "$service/Contents/MacOS/SceneBackendHelper"
python3 - "$service/Contents/Info.plist" "${SCENE_BACKEND_CLIENT_ID:-com.boneink.Glimmer.SceneBackendProbe}" <<'PY'
import plistlib,sys
value={'CFBundleIdentifier':'com.boneink.Glimmer.SceneBackend','CFBundleExecutable':'SceneBackendHelper',
       'CFBundlePackageType':'XPC!','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
       'XPCService':{'ServiceType':'Application','RunLoopType':'NSRunLoop'},
       'SceneBackendAllowedClients':[sys.argv[2]]}
with open(sys.argv[1],'wb') as f:plistlib.dump(value,f)
PY
# NSXPCConnections with one service identifier share one process. Eight explicit service
# identifiers give each simultaneous Scene a process while sharing the GPL framework binary.
for slot in {1..7}; do
  slot_service="$backend_build/SceneBackendHelperSlot$slot.xpc"
  ditto "$service" "$slot_service"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.boneink.Glimmer.SceneBackend.slot$slot" "$slot_service/Contents/Info.plist"
done
for packaged_service in "$backend_build"/SceneBackendHelper*.xpc; do
  codesign --force --timestamp=none --entitlements "$workspace_root/Sources/SceneBackendHelper/SceneBackendHelper.entitlements" --sign "$backend_signing_identity" "$packaged_service"
done
if [[ "${SCENE_BACKEND_BUILD_PROBE:-NO}" == "YES" ]]; then
  probe_app="$backend_build/SceneBackendProbe.app"
  mkdir -p "$probe_app/Contents/MacOS" "$probe_app/Contents/XPCServices" "$probe_app/Contents/Frameworks" "$probe_app/Contents/Resources"
  for packaged_service in "$backend_build"/SceneBackendHelper*.xpc; do
    ditto "$packaged_service" "$probe_app/Contents/XPCServices/$(basename "$packaged_service")"
  done
  ditto "$products/OpenWallpaperEngine.framework" "$probe_app/Contents/Frameworks/OpenWallpaperEngine.framework"
  ditto "$products/Sparkle.framework" "$probe_app/Contents/Frameworks/Sparkle.framework"
  for resource_bundle in "$products"/*.bundle; do
    [[ -e "$resource_bundle" ]] && ditto "$resource_bundle" "$probe_app/Contents/Resources/$(basename "$resource_bundle")"
  done
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -parse-as-library \
    "$workspace_root/Sources/SceneBackendHelper/Tests/SceneBackendProbe.swift" \
    -F "$products" -I "$products" \
    -Xcc "-fmodule-map-file=$module_maps/ShaderToolchain.modulemap" \
    -Xcc "-fmodule-map-file=$module_maps/CUfbx.modulemap" \
    -framework OpenWallpaperEngine -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -module-cache-path "$backend_build/probe-module-cache" -o "$probe_app/Contents/MacOS/SceneBackendProbe"
  python3 - "$probe_app/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:plistlib.dump({'CFBundleIdentifier':'com.boneink.Glimmer.SceneBackendProbe','CFBundleExecutable':'SceneBackendProbe','CFBundlePackageType':'APPL','CFBundleVersion':'1','LSUIElement':True},f)
PY
  # Existing stable Apple identity; no certificates, keychain ACLs or installed apps change.
  codesign --force --timestamp=none --sign "$backend_signing_identity" "$probe_app"
  codesign --verify --deep --strict "$probe_app"
fi
