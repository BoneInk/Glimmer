#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-workshop-web-import.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
source "$ROOT/scripts/author-web-core-sources.sh"
SOURCES=()
DESCRIPTOR="$ROOT/Sources/Glimmer/Support/WebWallpaperProjectDescriptor.swift"
HAS_DESCRIPTOR=false
for source in "${AUTHOR_WEB_CORE_SOURCES[@]}"; do
  if [[ "$source" == "$DESCRIPTOR" ]]; then HAS_DESCRIPTOR=true; fi
done
if [[ "$HAS_DESCRIPTOR" == false ]]; then SOURCES+=("$DESCRIPTOR"); fi
for directory in Model Store Media Import; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift;do SOURCES+=("$source");done
done
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" "${AUTHOR_WEB_CORE_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Tests/WorkshopWebImport/WorkshopWebImportTests.swift" -o "$WORK/WorkshopWebImportTests"
"$WORK/WorkshopWebImportTests" "${1:-$ROOT/evidence/workshop-web-import-tests.json}"
