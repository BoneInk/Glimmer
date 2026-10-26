#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-maximized-window-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWModuleSupport.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWPolicyModels.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWPolicyPersistence.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWMaximizedWindowDetector.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWAccessibilityWindowMonitor.swift" \
  "$ROOT/Sources/Glimmer/Policies/GWPolicyController.swift" \
  "$ROOT/Tests/MaximizedWindowPolicyTests.swift" -o "$WORK/probe"
"$WORK/probe" "$@"
