#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/gw-storage-protection.XXXXXX)"
cleanup() { python3 - "$WORK" <<'PY'
import shutil,sys
shutil.rmtree(sys.argv[1],ignore_errors=True)
PY
}
trap cleanup EXIT
cat > "$WORK/Stubs.swift" <<'SWIFT'
import Foundation
struct GWPersistencePaths { static var defaultRoot: URL { FileManager.default.temporaryDirectory } }
enum GWSettingsFormat {
    static func bytes(_ value: Int64) -> String { "\(value) bytes" }
    static func fileCount(_ count: Int) -> String { "\(count) files" }
}
SWIFT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
  "$WORK/Stubs.swift" \
  "$ROOT/Sources/Glimmer/Model/DisplayPlaybackSettings.swift" \
  "$ROOT/Sources/Glimmer/Model/WallpaperItem.swift" \
  "$ROOT/Sources/Glimmer/Settings/GWStorageCleanup.swift" \
  "$ROOT/Tests/StorageCleanupProjectProtectionTests.swift" \
  -o "$WORK/test"
"$WORK/test"
