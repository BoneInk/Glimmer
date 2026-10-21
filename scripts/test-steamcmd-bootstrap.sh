#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_OUT="$(mktemp -d "${TMPDIR:-/tmp}/glimmer-bootstrap-test.XXXXXX")"
trap 'rm -rf "$TEST_OUT"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Steam/SteamCMDBootstrap.swift" \
  "$ROOT/Sources/Glimmer/Steam/WorkshopProcessRunner.swift" \
  "$ROOT/Tests/SteamCMDBootstrapTests.swift" -o "$TEST_OUT/SteamCMDBootstrapTests"
"$TEST_OUT/SteamCMDBootstrapTests"
