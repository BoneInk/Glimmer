#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-rosetta-test.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Steam/RosettaInstallController.swift" \
  "$ROOT/Tests/RosettaInstallControllerTests.swift" \
  -o "$TEST_OUT/RosettaInstallControllerTests"
"$TEST_OUT/RosettaInstallControllerTests"
