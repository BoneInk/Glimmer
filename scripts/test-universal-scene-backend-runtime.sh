#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /private/tmp/gw-universal-scene-runtime.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM
cat > "$WORK/SceneVector2.swift" <<'SWIFT'
import Foundation
struct SceneVector2: Codable, Equatable, Sendable {
    var x: Double; var y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
}
SWIFT
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/SceneBackendShared/SceneBackendTypes.swift" \
  "$ROOT/Sources/Glimmer/SteamContent/SteamContentTypes.swift" \
  "$ROOT/Sources/Glimmer/Support/SceneRuntimeAssetRegistry.swift" \
  "$ROOT/Sources/Glimmer/Support/AppConstants.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/GWJSONValue.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyCondition.swift" \
  "$ROOT/Sources/Glimmer/AuthorProperties/AuthorPropertyProject.swift" \
  "$WORK/SceneVector2.swift" "$ROOT"/Sources/Glimmer/SceneBackend/*.swift \
  "$ROOT/Tests/SceneWallpaper/UniversalSceneBackendRuntimeTests.swift" \
  -framework AppKit -framework CoreImage -framework IOSurface -framework Metal -framework MetalKit \
  -o "$WORK/probe"
"$WORK/probe" "${1:-$WORK/report.json}"
