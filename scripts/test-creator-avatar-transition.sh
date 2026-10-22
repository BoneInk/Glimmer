#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/glimmer-creator-avatar.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/UI/Workshop/WorkshopCreatorAvatarTransition.swift" \
  "$ROOT/Tests/WorkshopCreatorAvatarTransitionTests.swift" \
  -framework AppKit -framework SwiftUI -o "$WORK/probe"
"$WORK/probe"
