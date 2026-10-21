#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$1"
EXT="${2:-$APP/Contents/PlugIns/GlimmerWallpaperExtension.appex}"
[[ -d "$APP/Contents/XPCServices/SceneBackendHelper.xpc" && -d "$EXT" ]]
source "$ROOT/scripts/signing-identity.sh"
SIGN="$(gw_resolve_signing_identity)"
mkdir -p "$EXT/Contents/XPCServices" "$EXT/Contents/Frameworks"
for framework in OpenWallpaperEngine Sparkle; do
  ditto "$APP/Contents/Frameworks/$framework.framework" "$EXT/Contents/Frameworks/$framework.framework"
done
for slot in {0..7}; do
  SERVICE="$EXT/Contents/XPCServices/LockScreenScene$slot.xpc"
  ditto "$APP/Contents/XPCServices/SceneBackendHelper.xpc" "$SERVICE"
  python3 - "$SERVICE/Contents/Info.plist" "$slot" <<'PY'
import pathlib,plistlib,sys
p=pathlib.Path(sys.argv[1]);v=plistlib.loads(p.read_bytes())
v['CFBundleIdentifier']='com.boneink.Glimmer.LockScreenScene.slot'+sys.argv[2]
v['SceneBackendAllowedClients']=['com.boneinkzhong.glimmer.wallpaper-extension']
p.write_bytes(plistlib.dumps(v))
PY
  codesign --force --timestamp=none --entitlements "$ROOT/Sources/SceneBackendHelper/SceneBackendHelper.entitlements" --sign "$SIGN" "$SERVICE"
done
codesign --force --timestamp=none --entitlements "$ROOT/Extensions/GlimmerWallpaperExtension/Extension.entitlements" --sign "$SIGN" "$EXT"
codesign --verify --deep --strict "$EXT"
