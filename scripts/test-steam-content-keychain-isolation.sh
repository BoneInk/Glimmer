#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/gw-steam-keychain-probe.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
 "$ROOT/Sources/Glimmer/SteamContent/SteamContentSessionStore.swift" \
 "$ROOT/Tests/SteamContent/KeychainIsolationProbe.swift" -o "$WORK/probe"
codesign --force --sign - "$WORK/probe" >&2
"$WORK/probe" "$WORK"
