#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/gw-scene-builtins.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
mkdir -p "$ROOT/evidence/scene-script-builtins"
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library -target arm64-apple-macos26.0 -framework JavaScriptCore \
  "$ROOT/Tests/SceneWallpaper/SceneScriptBuiltinsTests.swift" -o "$OUT/probe"
"$OUT/probe" "$ROOT/Workers/SceneScript/SceneScriptBuiltins.js" | tee "$ROOT/evidence/scene-script-builtins/probe.json"
