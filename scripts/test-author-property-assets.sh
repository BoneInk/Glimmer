#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-author-assets.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT"/Sources/Glimmer/AuthorProperties/*.swift \
 "$ROOT"/Sources/Glimmer/AuthorPropertyAssets/*.swift \
 "$ROOT/Tests/AuthorPropertyAssetTests.swift" -o "$WORK/probe"
"$WORK/probe"
