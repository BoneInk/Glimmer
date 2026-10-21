#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/gw-download-metrics.XXXXXX")"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$OUT"' EXIT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -target arm64-apple-macos26.0 \
  "$ROOT/Sources/Glimmer/Steam/WorkshopDownloadMetrics.swift" \
  "$ROOT/Tests/WorkshopDownloadMetricsTests.swift" -o "$OUT/probe"
"$OUT/probe"
