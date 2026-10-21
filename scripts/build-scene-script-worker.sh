#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/signing-identity.sh"
SIGN_IDENTITY="$(gw_resolve_signing_identity)"
OUT="${GW_SCENE_WORKER_OUT:-$ROOT/build/SceneScriptWorker}"
mkdir -p "$OUT"
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys,base64
r=Path(sys.argv[1]);out=Path(sys.argv[2])
import json
scope=r/'Workers/SceneScript/ThirdParty/ModuleScope'
bundle='(function(){const factories={'
for index,(name,file) in enumerate([('estraverse','estraverse.js'),('esrecurse','esrecurse.js'),('eslint-scope','eslint-scope.cjs')]):
 if index:bundle+=','
 bundle+=json.dumps(name)+':function(module,exports,require){\n'+(scope/name/file).read_text()+'\n}'
bundle+='};const cache=Object.create(null);function load(name){if(cache[name])return cache[name].exports;const module={exports:{}};cache[name]=module;factories[name](module,module.exports,function(dep){if(dep==="./package.json")return {version:"4.3.0"};return load(dep);});return module.exports;}return load("eslint-scope");})()'
(out/'SceneScriptScope.js').write_text(bundle)
parts={"acorn":r/'Workers/SceneScript/ThirdParty/Acorn/acorn.js',"scope":out/'SceneScriptScope.js',"modules":r/'Workers/SceneScript/SceneScriptModules.js',"hierarchy":r/'Workers/SceneScript/SceneScriptHierarchy.js',"builtins":r/'Workers/SceneScript/SceneScriptBuiltins.js',"engine":r/'Workers/SceneScript/SceneScriptEngine.js'}
s='import Foundation\nenum SceneScriptEngineSource {\n'
for key,p in parts.items():
 s+='static let '+key+' = String(data: Data(base64Encoded: "'+base64.b64encode(p.read_bytes()).decode()+'")!, encoding: .utf8)!\n'
(out/'SceneScriptEngineSource.swift').write_text(s+'}\n')
PY
swiftc -swift-version 6 -O -target arm64-apple-macos26.0 -framework JavaScriptCore \
  "$ROOT/Workers/SceneScript/main.swift" "$OUT/SceneScriptEngineSource.swift" \
  -o "$OUT/GlimmerSceneScriptWorker"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$OUT/GlimmerSceneScriptWorker"
printf 'SceneScript worker: %s\n' "$OUT/GlimmerSceneScriptWorker"
