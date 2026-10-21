#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-author-properties.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
 "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyOverrideStore.swift" \
 "$ROOT/Tests/AuthorProperties/AuthorPropertyTests.swift" -o "$WORK/probe"
"$WORK/probe" "$ROOT/Tests/AuthorProperties/Fixtures/authored-web-project.json"
