#!/usr/bin/env bash
# The local gate: builds the test build and runs the whole suite the way CI does (every test
# class, parallel then serial, failing tests retried once), then prints the failures with their
# messages and the 25 slowest tests with where their time went. A PR should pass it before
# merging; CI is the safety net. The test build is optimised (Scripts/test-build-settings.txt),
# as on CI.
#
#   Scripts/ci-local.sh                         the suite; the asset-gated tests skip
#   OWE_ASSETS=<assets folder> Scripts/ci-local.sh
#                                               with the asset tests (Scripts/fetch-we-assets.sh)
#   OWE_SLOW_TESTS=1 Scripts/ci-local.sh        with the slow tests, as the nightly runs them
#   Scripts/ci-local.sh --no-build              reuses the last test build
#
# The build and the results go to build/ci-local (OWE_CI_LOCAL_DIR to change it); every test's
# duration and phase times go to <that>/results/durations.csv.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
OUT=${OWE_CI_LOCAL_DIR:-build/ci-local}
BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -n "${OWE_ASSETS:-}" ]]; then
  [[ -d "$OWE_ASSETS" ]] || { echo "OWE_ASSETS is not a folder: $OWE_ASSETS" >&2; exit 2; }
  export TEST_RUNNER_OWE_ASSETS="$OWE_ASSETS"
fi
[[ "${OWE_SLOW_TESTS:-}" == 1 ]] && export TEST_RUNNER_OWE_SLOW_TESTS=1
mkdir -p "$OUT"

if (( BUILD )); then
  echo "Building for testing into $OUT/DerivedData…"
  read -ra OPTIMISE < Scripts/test-build-settings.txt
  if ! xcodebuild build-for-testing \
      -project OpenWallpaperEngine.xcodeproj \
      -scheme OpenWallpaperEngine \
      -configuration Debug \
      -destination platform=macOS \
      -derivedDataPath "$OUT/DerivedData" \
      CODE_SIGNING_ALLOWED=NO \
      COMPILER_INDEX_STORE_ENABLE=NO \
      "${OPTIMISE[@]}" > "$OUT/build.log" 2>&1; then
    grep -E "error:" "$OUT/build.log" | sort -u | head -40
    echo "Build failed; the full log is $OUT/build.log" >&2
    exit 1
  fi
fi

runs=("$OUT"/DerivedData/Build/Products/*.xctestrun)
XCTESTRUN=${runs[0]}
[[ -f "$XCTESTRUN" ]] || { echo "No test build in $OUT; run without --no-build." >&2; exit 1; }

python3 Scripts/ci-test-plan.py classes > "$OUT/classes.txt"
echo "Testing $(wc -l < "$OUT/classes.txt" | tr -d ' ') classes" \
  "(assets: ${TEST_RUNNER_OWE_ASSETS:-no}, slow tests: ${TEST_RUNNER_OWE_SLOW_TESTS:-no})."
echo "Output: $OUT/results/xcodebuild.log"

Scripts/ci-run-tests.sh "$XCTESTRUN" "$OUT/classes.txt" "$OUT/results" > /dev/null
status=$?

echo
python3 Scripts/ci-test-durations.py --text --phases "$OUT/results/phases" --csv "$OUT/results/durations.csv" \
  "$OUT/results/parallel.xcresult" "$OUT/results/serial.xcresult"
echo "Every test's duration: $OUT/results/durations.csv"
echo
python3 Scripts/ci-test-summary.py --text --env "$OUT/results/parallel.xcresult" "$OUT/results/serial.xcresult"
if (( status == 0 )); then
  echo "Passed."
else
  echo "FAILED. Details: $OUT/results/xcodebuild.log and the .xcresult bundles in $OUT/results." >&2
fi
exit "$status"
