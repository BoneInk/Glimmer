#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/evidence/scene-script-hierarchy"
python3 - "$ROOT" <<'PY'
import pathlib,tempfile,subprocess,shutil,hashlib,json,os,sys
root=pathlib.Path(sys.argv[1]); out=root/'evidence/scene-script-hierarchy'
with tempfile.TemporaryDirectory(prefix='gw-hierarchy-worker-') as folder:
    folder=pathlib.Path(folder); worker=folder/'GlimmerSceneScriptWorker'
    shutil.copy2(os.environ.get('SCENE_SCRIPT_WORKER',str(root/'build/SceneScriptWorker/GlimmerSceneScriptWorker')),worker)
    sources=['AuthorProperties/GWJSONValue.swift','SceneWallpaper/SceneWallpaperTypes.swift','SceneWallpaper/SceneHierarchy.swift','SceneWallpaper/SceneScriptSpec.swift','SceneScript/SceneScriptWorkerClient.swift']
    args=['xcrun','swiftc','-swift-version','6','-strict-concurrency=complete','-warnings-as-errors','-target','arm64-apple-macos26.0']
    args += [str(root/'Sources/Glimmer'/p) for p in sources]
    args += [str(root/'Tests/SceneWallpaper/SceneScriptHierarchyProbe.swift'),'-o',str(folder/'probe')]
    subprocess.run(args,check=True)
    (out/'copied-helper.json').write_text(json.dumps({'sha256':hashlib.sha256(worker.read_bytes()).hexdigest()},indent=2)+'\n')
    subprocess.run([str(folder/'probe'),str(worker),str(out/'probe.json')],check=True)
PY
