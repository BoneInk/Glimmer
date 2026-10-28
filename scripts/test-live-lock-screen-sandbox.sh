#!/bin/bash
# Real signed sandbox rendering; synthetic fixtures and review stores only.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${GW_LIVE_LOCK_SCREEN_APP:-$ROOT/build/live-lock-screen/Glimmer.app}"
OUT="${GW_LIVE_LOCK_SCREEN_EVIDENCE:-$ROOT/evidence/live-lock-screen}"
PROFILE="${GW_SCENE_EXPORT_ASSET_PROFILE:-$HOME/Library/Application Support/Glimmer}"
[[ -d "$APP/Contents/PlugIns/GlimmerWallpaperExtension.appex/Contents/XPCServices" ]] || { echo 'Build the full live-lock-screen app first.' >&2; exit 1; }
WORK="$(mktemp -d /tmp/glimmer-live-sandbox.XXXXXX)"
FIXTURES=""
cleanup() { rm -rf "$WORK"; if [[ -n "$FIXTURES" ]]; then rm -rf "$FIXTURES"; fi; }
trap cleanup EXIT
mkdir -p "$OUT"
bash "$ROOT/scripts/build-wallpaper-extension.sh" --diagnostic-entry --output "$WORK/Probe.bundle"
bash "$ROOT/scripts/embed-lock-screen-scene-backend.sh" "$APP" "$WORK/Probe.bundle"
cat > "$WORK/MakeVideo.swift" <<'SWIFT'
import Foundation
@main struct MakeVideo {
    static func main() async throws {
        try await SyntheticVideoWriter.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
SWIFT
swiftc -parse-as-library "$ROOT/Sources/Glimmer/Media/SyntheticVideoWriter.swift" "$WORK/MakeVideo.swift" -o "$WORK/make-video"
"$WORK/make-video" "$WORK/video.mp4"
FIXTURES="$(python3 "$ROOT/Tests/LiveLockScreenFixtureBuilder.py" "$PROFILE" "$WORK/video.mp4")"
GW_CONFIGURED_EXPORT_APP="$APP" GW_LIVE_PROBE_FIXTURES="$FIXTURES" GW_SCENE_EXPORT_ASSET_PROFILE="$PROFILE" \
  bash "$ROOT/scripts/test-live-lock-screen-preparation.sh" > "$OUT/preparation.log" 2>&1
for kind in scene web web-network prepared-scene prepared-web; do
  python3 "$ROOT/Tests/NativeWallpaperRecoveryDriver.py" \
    "$WORK/Probe.bundle/Contents/MacOS/GlimmerWallpaperExtension" "$FIXTURES/$kind" "$OUT/$kind"
done
python3 - "$OUT" <<'PY'
import pathlib,json,sys
p=pathlib.Path(sys.argv[1])
for kind in ['scene','web','web-network','prepared-scene','prepared-web']:
    value=json.loads((p/(kind+'.json')).read_text())
    assert value['success'] and value['sandboxActive'] and not value['systemWallpaperModified'], value
    assert value['pausedFrameHeld'] and value['resumedChangingFrames'], value
    if 'web' not in kind: assert value['frameCount']>8, value
    assert value['ownedHelperExited'] and value['releasedContextAndFrames'], value
    assert value['defaultModePlayback'] and value['sleepFrameHeld'] and value['wakeResumedSameContext'], value
    assert value['contextXPCTransport'] and value['snapshotXPCTransport'], value
    assert value['boundedRecoveryPreservesImage'] and value['wakeResetsRecoveryBudget'], value
    if 'web' not in kind:
        assert value['lostHelperWhileAsleepHoldsImage'] and value['wakeRebuildsLostHelper'], value
        assert value['activeHelperDisconnectRecovers'], value
    if 'web' in kind:
        assert value['contentProcessTerminationRecovers'] and value['recoveredClockCurrent'] and value['stopCancelsRecovery'], value
        assert value['currentWallClockAfterPause'] and value['hiddenWebDocumentReleased'], value
        assert value['videoPlayingAfterWake'] and value['pageAudioMuted'] and value['noPeriodicSnapshots'], value
        assert value['measurement']['snapshotsDuringPlayback']==0 and value['resumedMeasurement']['snapshotsDuringPlayback']==0, value
        assert 3 <= value['documentCount'] and value['snapshotCount'] <= 12, value
        assert value['webRenderHostUnshown'], value
    if kind=='web': assert value['networkResult']=='blocked', value
    if kind in ['web-network','prepared-web']: assert value['networkResult']=='allowed', value
print('PASS: real sandbox Scene/Web frames, clock resume, optional HTTPS weather, private production staging, pause/release and XPC composition; actual system store unchanged')
PY
