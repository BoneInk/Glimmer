#!/bin/zsh
set -eu
workspace_root=$(cd "$(dirname "$0")/.." && pwd)
[[ $# == 1 ]] || { echo 'Usage: embed-scene-backend.sh APP.app' >&2; exit 2; }
app="$1"
main_id=com.boneinkzhong.glimmer
backend_build=${SCENE_BACKEND_BUILD_DIR:-"$workspace_root/build/SceneBackend"}
python3 - "$app" "$main_id" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1])
if not app.is_absolute() or not app.is_dir():raise SystemExit('APP must be an existing absolute app directory')
info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier')!=sys.argv[2]:raise SystemExit('Unexpected main app bundle identifier')
PY
SCENE_BACKEND_BUILD_PROBE=NO SCENE_BACKEND_CLIENT_ID="$main_id" SCENE_BACKEND_BUILD_DIR="$backend_build" "$workspace_root/scripts/build-scene-backend.sh"
mkdir -p "$app/Contents/XPCServices" "$app/Contents/Frameworks" "$app/Contents/Resources/SceneBackendLicenses"
for service in "$backend_build"/SceneBackendHelper*.xpc; do
  ditto "$service" "$app/Contents/XPCServices/$(basename "$service")"
done
for framework in OpenWallpaperEngine Sparkle; do
  ditto "$backend_build/products/Release/$framework.framework" "$app/Contents/Frameworks/$framework.framework"
done
for resource_bundle in "$backend_build/products/Release"/*.bundle; do
  [[ -e "$resource_bundle" ]] && ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done
python3 - "$workspace_root" "$app" "$main_id" <<'PY'
from pathlib import Path
import json,plistlib,shutil,sys
root,app=map(Path,sys.argv[1:3]); main=sys.argv[3]; vendor=root/'Vendor/OpenWallpaperEngine'
licenses=app/'Contents/Resources/SceneBackendLicenses'
for source in vendor.rglob('*'):
 if source.is_file() and not source.is_symlink() and source.name.upper() in {'LICENSE','LICENSE.TXT','LICENSE.MD','COPYING','COPYING.TXT','NOTICE','NOTICE.TXT'}:
  rel=source.relative_to(vendor)
  if any(part in {'.git','.build','build','.swiftpm','xcuserdata'} for part in rel.parts):continue
  target=licenses/rel;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
for i in range(8):
 name='SceneBackendHelper.xpc' if i==0 else f'SceneBackendHelperSlot{i}.xpc'
 service=app/'Contents/XPCServices'/name
 info=plistlib.loads((service/'Contents/Info.plist').read_bytes())
 expected='com.boneink.Glimmer.SceneBackend'+(f'.slot{i}' if i else '')
 assert info['CFBundleIdentifier']==expected
 assert info['SceneBackendAllowedClients']==[main]
 assert 'SceneBackendResearchAllowAdHoc' not in info
shutil.copyfile(vendor/'GLIMMER-PROVENANCE.json',app/'Contents/Resources/SceneBackend-Provenance.json')
(app/'Contents/Resources/SceneBackend-NOTICE.txt').write_text('Open Wallpaper Engine Scene backend\nPinned source: https://github.com/deepratna-awale/open-wallpaper-engine-mac\nCommit: 8d9e86d16e87395d0ab46710b05ecc24fd992539\nThe helper/framework contains GPL-3.0 repository code; component licenses are included in SceneBackendLicenses.\nCorresponding integration source is included in SceneBackendSource.tar.gz.\nOriginal Glimmer code retains its MIT notices. The main app uses IPC and does not link the GPL framework.\nPrivate Wallpaper Engine assets and user projects are not distributed in this bundle.\n')
PY
# An explicit source allowlist excludes research assets, credentials, caches and build products.
COPYFILE_DISABLE=1 tar -czf "$app/Contents/Resources/SceneBackendSource.tar.gz" \
  --exclude='.git' --exclude='.build' --exclude='build' --exclude='.swiftpm' \
  --exclude='xcuserdata' --exclude='.DS_Store' --exclude='*.xcuserstate' \
  -C "$workspace_root" LICENSE Vendor/OpenWallpaperEngine Sources/SceneBackendShared Sources/SceneBackendHelper \
  scripts/build-scene-backend.sh scripts/embed-scene-backend.sh scripts/signing-identity.sh
python3 - "$app" <<'PY'
from pathlib import Path
import hashlib,json,sys,tarfile
app=Path(sys.argv[1]);archive=app/'Contents/Resources/SceneBackendSource.tar.gz'
with tarfile.open(archive) as tar:
 for entry in tar:
  parts=Path(entry.name).parts
  assert parts and '..' not in parts and not entry.name.startswith('/')
  assert not any(p in {'.git','.build','build','.swiftpm','xcuserdata','SteamContent','scene-runtime-assets'} for p in parts)
  if entry.issym():assert not entry.linkname.startswith('/')
metadata={'protocolVersion':1,'serviceCount':8,'mainAppLinksGPLFramework':False,
 'sourceArchiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),'privateOfficialAssetsIncluded':False,
 'upstreamCommit':'8d9e86d16e87395d0ab46710b05ecc24fd992539'}
(app/'Contents/Resources/SceneBackend-Embedded.json').write_text(json.dumps(metadata,indent=2))
PY
# Each nested service is already signed with its minimal JIT entitlement. Never deep re-sign.
for service in "$app/Contents/XPCServices"/SceneBackendHelper*.xpc; do
  codesign --verify --deep --strict "$service"
done
for framework in OpenWallpaperEngine Sparkle; do
  codesign --verify --deep --strict "$app/Contents/Frameworks/$framework.framework"
done
