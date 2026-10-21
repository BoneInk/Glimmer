#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/scene-inspection-core-sources.sh"
WORK="$(mktemp -d /tmp/gw-scene-parent-parser.XXXXXX)"
# TemporaryDirectory cleanup is explicit and restricted to this fixture path.
cleanup() { python3 - "$WORK" <<'PY'
import pathlib,shutil,sys
p=pathlib.Path(sys.argv[1])
if p.name.startswith('gw-scene-parent-parser.') and p.parent==pathlib.Path('/tmp'):
    shutil.rmtree(p)
PY
}
trap cleanup EXIT
mkdir -p "$ROOT/evidence/scene-parent-parser"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
 "${SCENE_INSPECTION_CORE_SOURCES[@]}" "$ROOT/Tests/SceneWallpaper/SceneParentParserTests.swift" -o "$WORK/probe"
"$WORK/probe" | tee "$ROOT/evidence/scene-parent-parser/probe.txt"
