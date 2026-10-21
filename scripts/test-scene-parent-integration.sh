#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-parent-desktop.XXXXXX")"
RUN_JSON="$ROOT/evidence/scene-parent-integration/run.json"
EVIDENCE_CREATED=0
cleanup() {
  local exit_code=$?
  if [[ "$EVIDENCE_CREATED" == 1 && "$exit_code" != 0 ]]; then
    /usr/bin/python3 - "$RUN_JSON" "$exit_code" <<'PY'
import datetime,json,pathlib,sys
p=pathlib.Path(sys.argv[1]);record=json.loads(p.read_text())
record.update(status="failed",exitCode=int(sys.argv[2]),completedAt=datetime.datetime.now(datetime.timezone.utc).isoformat())
p.write_text(json.dumps(record,indent=2,sort_keys=True)+"\n")
PY
  fi
  rm -rf "$TEST_OUT"
}
trap cleanup EXIT
APP="$TEST_OUT/SceneParentProbe.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$ROOT/evidence/scene-parent-integration"
cp "$ROOT/build/SceneScriptWorker/GlimmerSceneScriptWorker" "$APP/Contents/Helpers/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.boneinkzhong.glimmer.scene-parent-probe</string><key>CFBundleExecutable</key><string>SceneParentProbe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
SOURCES=()
for directory in Steam Store Model Import Media Display Desktop; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
source "$ROOT/scripts/author-web-core-sources.sh"
COMPILE_SOURCES=("${AUTHOR_WEB_CORE_SOURCES[@]}" "${SOURCES[@]}"
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift"
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift"
  "$ROOT/Sources/Glimmer/Support/WorkshopWallpaperApplication.swift"
  "$ROOT/Sources/Glimmer/Support/ManagedWallpaperDeletionService.swift"
  "$ROOT/Tests/SceneWallpaper/SceneParentIntegrationTests.swift")
/usr/bin/python3 - "$ROOT" "$APP/Contents/Helpers/GlimmerSceneScriptWorker" "$RUN_JSON" "${COMPILE_SOURCES[@]}" <<'PY'
import datetime,hashlib,json,pathlib,sys,uuid
root=pathlib.Path(sys.argv[1]);helper=pathlib.Path(sys.argv[2]);output=pathlib.Path(sys.argv[3])
digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources={str(pathlib.Path(p).relative_to(root)):digest(pathlib.Path(p)) for p in sys.argv[4:]}
record=dict(runID=str(uuid.uuid4()),status="running",phase="compiling",startedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),checks=None,
 command="bash scripts/test-scene-parent-integration.sh",copiedHelperSHA256=digest(helper),copiedHelperPath=str(helper),
 testSourceSHA256=sources["Tests/SceneWallpaper/SceneParentIntegrationTests.swift"],compiledSourcesSHA256=sources,
 scriptSHA256=digest(root/"scripts/test-scene-parent-integration.sh"),fixture="Tests/Fixtures/SceneHierarchyWallpaper",
 isolation="Random temporary app/store/source; two snapshot virtual displays previewOnly; no user desktop/lock/account changes")
output.write_text(json.dumps(record,indent=2,sort_keys=True)+"\n")
PY
EVIDENCE_CREATED=1
swiftc "${COMPILE_SOURCES[@]}" -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 -o "$APP/Contents/MacOS/SceneParentProbe"
codesign --force --sign - --timestamp=none "$APP"
/usr/bin/python3 - "$ROOT" "$RUN_JSON" "$APP/Contents/Helpers/GlimmerSceneScriptWorker" "$APP/Contents/MacOS/SceneParentProbe" <<'PY'
import datetime,hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);p=pathlib.Path(sys.argv[2]);r=json.loads(p.read_text());digest=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
for name,expected in r["compiledSourcesSHA256"].items():
 if digest(root/name)!=expected:raise SystemExit("Compiled source changed during probe build: "+name)
if digest(pathlib.Path(sys.argv[3]))!=r["copiedHelperSHA256"]:raise SystemExit("Copied helper changed during probe build")
r.update(phase="executing",executionStartedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),probeExecutableSHA256=digest(pathlib.Path(sys.argv[4])))
p.write_text(json.dumps(r,indent=2,sort_keys=True)+"\n")
PY
"$APP/Contents/MacOS/SceneParentProbe" "$ROOT/Tests/Fixtures/SceneHierarchyWallpaper" | tee "$ROOT/evidence/scene-parent-integration/probe.txt"
/usr/bin/python3 - "$RUN_JSON" "$ROOT/evidence/scene-parent-integration/probe.txt" <<'PY'
import datetime,json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]);r=json.loads(p.read_text());log=pathlib.Path(sys.argv[2]).read_text();match=re.search(r"^RESULT (\d+) parent import/Services/",log,re.M)
if not match or int(match.group(1))!=30:raise SystemExit("Missing successful 30-check result")
r.update(status="passed",phase="completed",checks=int(match.group(1)),completedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),transcript="evidence/scene-parent-integration/probe.txt")
p.write_text(json.dumps(r,indent=2,sort_keys=True)+"\n")
PY
