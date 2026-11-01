#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /private/tmp/glimmer-display-playback-policy.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
source "$ROOT/scripts/author-web-core-sources.sh"
SOURCES=()
for directory in Model Store Media Display Desktop Policies Playlist; do
  for source in "$ROOT/Sources/Glimmer/$directory/"*.swift; do SOURCES+=("$source"); done
done
swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-macos26.0 \
  "${SOURCES[@]}" "${AUTHOR_WEB_CORE_SOURCES[@]}" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/Support/VideoFileSupport.swift" \
  "$ROOT/Sources/Glimmer/Support/AppPlaybackIntegration.swift" \
  "$ROOT/Tests/DisplayPlaybackPolicyIntegrationTests.swift" -o "$WORK/probe"
"$WORK/probe"
