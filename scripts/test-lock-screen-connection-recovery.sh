#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glimmer-connection-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
  -target arm64-apple-macos26.0 -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  "$ROOT/Sources/Glimmer/LockScreen/LockScreenConnectionRecovery.swift" \
  "$ROOT/Tests/LockScreenConnectionRecoveryTests.swift" -o "$WORK/probe"
"$WORK/probe"
