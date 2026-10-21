#!/usr/bin/env bash
# Runs a list of test classes from a test build the way CI does:
#   1. the non-serial classes with three parallel workers,
#   2. then the serial classes of .github/test-map.yml one at a time.
# A failing test is retried once (-retry-tests-on-failure -test-iterations 2); a test that fails
# both times fails the run. Both parts run even if the first fails. Each part writes a result
# bundle to the results folder, and all output goes to <results>/xcodebuild.log as well. Each
# test's time per phase (scene load, shader translate, render, …) goes to <results>/phases, for
# Scripts/ci-test-durations.py (TEST_RUNNER_OWE_TEST_PHASES= turns that off).
#
# Usage: Scripts/ci-run-tests.sh <xctestrun> <classes file> <results folder>
# The environment passes through: TEST_RUNNER_OWE_ASSETS, TEST_RUNNER_OWE_SLOW_TESTS, …
set -uo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <xctestrun> <classes file> <results folder>" >&2
  exit 2
fi
XCTESTRUN=$1 CLASSES=$2 RESULTS=$3
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$RESULTS"
RESULTS=$(cd "$RESULTS" && pwd)
LOG="$RESULTS/xcodebuild.log"
: > "$LOG"
if [[ -z "${TEST_RUNNER_OWE_TEST_PHASES+set}" ]]; then
  export TEST_RUNNER_OWE_TEST_PHASES="$RESULTS/phases"
fi
if [[ -n "$TEST_RUNNER_OWE_TEST_PHASES" ]]; then
  mkdir -p "$TEST_RUNNER_OWE_TEST_PHASES" && rm -f "$TEST_RUNNER_OWE_TEST_PHASES"/phases-*.jsonl
fi

SERIAL=" $(python3 "$HERE/ci-test-plan.py" serial | tr '\n' ' ') "
PARALLEL_ONLY=() SERIAL_ONLY=()
while read -r cls; do
  [[ -n "$cls" ]] || continue
  if [[ "$SERIAL" == *" $cls "* ]]; then
    SERIAL_ONLY+=("-only-testing:OpenWallpaperEngineTests/$cls")
  else
    PARALLEL_ONLY+=("-only-testing:OpenWallpaperEngineTests/$cls")
  fi
done < "$CLASSES"

echo "Running ${#PARALLEL_ONLY[@]} classes in parallel, then ${#SERIAL_ONLY[@]} serially."

COMMON=(-xctestrun "$XCTESTRUN" -destination platform=macOS -retry-tests-on-failure -test-iterations 2)
status=0

if (( ${#PARALLEL_ONLY[@]} )); then
  rm -rf "$RESULTS/parallel.xcresult"
  xcodebuild test-without-building "${COMMON[@]}" \
    -parallel-testing-enabled YES -parallel-testing-worker-count 3 \
    -resultBundlePath "$RESULTS/parallel.xcresult" \
    "${PARALLEL_ONLY[@]}" 2>&1 | tee -a "$LOG" || status=1
fi

if (( ${#SERIAL_ONLY[@]} )); then
  rm -rf "$RESULTS/serial.xcresult"
  xcodebuild test-without-building "${COMMON[@]}" \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULTS/serial.xcresult" \
    "${SERIAL_ONLY[@]}" 2>&1 | tee -a "$LOG" || status=1
fi

exit "$status"
