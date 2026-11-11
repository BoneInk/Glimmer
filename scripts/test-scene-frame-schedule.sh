#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORK=$(mktemp -d /private/tmp/gw-scene-frame-schedule.XXXXXX)
trap 'rm -rf "$WORK"' EXIT INT TERM
swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors -parse-as-library \
  "$ROOT/Sources/SceneBackendShared/SceneFrameSchedule.swift" \
  "$ROOT/Tests/SceneWallpaper/SceneFrameScheduleTests.swift" -o "$WORK/probe"
"$WORK/probe"
