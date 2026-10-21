#!/bin/bash
# Builds only the extension, stages synthetic demo fixtures, never registers or applies it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${GW_PROBE_EVIDENCE_DIR:-$ROOT/evidence/native-wallpaper-extension}"
mkdir -p "$OUT"
WORK="$(mktemp -d /tmp/glass-native-extension-probe.XXXXXX)"
PROBE=""
cleanup() {
  if [ -n "$PROBE" ]; then rm -rf "$PROBE"; fi
  rm -rf "$WORK"
}
trap cleanup EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
"$ROOT/scripts/build-wallpaper-extension.sh" --output "$WORK/GlimmerWallpaperExtension.appex"
"$ROOT/scripts/build-wallpaper-extension.sh" --diagnostic-entry --output "$WORK/GlimmerWallpaperDiagnostics.bundle"
BIN="$WORK/GlimmerWallpaperDiagnostics.bundle/Contents/MacOS/GlimmerWallpaperExtension"
"$BIN" --runtime-probe > "$OUT/runtime-probe.json"
PROBE="$(python3 - "$ROOT/evidence/ui-test-video.mp4" <<'PY'
from pathlib import Path
import os,stat,uuid,json,shutil,sys
root=Path('/Users/Shared/GlimmerNativeLockScreen')
if not root.exists():root.mkdir(mode=0o755)
assert root.lstat().st_uid in (0,os.getuid()) and not root.is_symlink() and root.stat().st_mode&0o022==0
user=root/str(os.getuid())
if not user.exists():user.mkdir(mode=0o700)
assert user.lstat().st_uid==os.getuid() and not user.is_symlink() and user.stat().st_mode&0o077==0
probe=user/('isolated-probe-'+str(uuid.uuid4()));probe.mkdir(mode=0o700)
asset=uuid.uuid4();video=probe/(str(asset)+'.mp4');shutil.copyfile(sys.argv[1],video);video.chmod(0o600)
config=dict(schemaVersion=1,assetID=str(asset),videoFileName=video.name,gravity='fill',isMuted=True)
for name in ['valid','traversal','symlink','publicfile','publicfolder','unmuted']:
 d=probe/name;d.mkdir(mode=0o700);v=d/video.name;shutil.copyfile(video,v);v.chmod(0o600)
 c=config.copy()
 if name=='traversal':c['videoFileName']='../'+video.name
 if name=='unmuted':c['isMuted']=False
 if name=='symlink':v.unlink();v.symlink_to(video)
 if name=='publicfile':v.chmod(0o644)
 if name=='publicfolder':d.chmod(0o755)
 f=d/'config.json';f.write_text(json.dumps(c));f.chmod(0o600)
print(probe)
PY
)"
"$BIN" --isolated-video-probe "$PROBE/valid" > "$OUT/video-probe.json"
"$BIN" --validate-staged-config "$PROBE/valid" > "$OUT/config-valid.json"
for case in traversal symlink publicfile publicfolder unmuted; do
  if "$BIN" --validate-staged-config "$PROBE/$case" > "$OUT/config-$case.json"; then
    echo "FAIL: unsafe configuration accepted: $case" >&2
    exit 1
  fi
done
python3 - "$OUT" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);r=json.loads((p/'runtime-probe.json').read_text());v=json.loads((p/'video-probe.json').read_text())
assert r['sandboxActive'] and r['privateFrameworkLoaded'] and r['settingsObjectCreated'] and r['settingsSecureRoundTrip']
assert v['sandboxActive'] and v['decodedFramesEnqueued']>=8 and v['differentFrameSignatures']>=2
assert v['snapshotXPCTransportRoundTrip'] and v['remoteContextXPCTransportRoundTrip']
assert v['muted'] and v['volume']==0 and not v['systemWallpaperModified']
assert v['desktopModePausesWithoutFrameLoop'] and v['previewOrLockedModeResumes'] and v['stopReleasesPlayerContextAndBuffer']
print('PASS: sandbox/private-runtime/settings, real changing video frames in remote CAContext, snapshot/context XPC transport, 5 unsafe staging cases rejected; no registration or wallpaper changes.')
PY
# Preserve only the signed package, never the staged demo/config or captured frames.
mkdir -p "$OUT/GlimmerWallpaperExtension.appex"
cp -R "$WORK/GlimmerWallpaperExtension.appex/." "$OUT/GlimmerWallpaperExtension.appex/"
