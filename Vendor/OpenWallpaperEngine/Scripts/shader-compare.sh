#!/bin/zsh
# Runs the shader comparison suite (OpenWallpaperEngineTests/ShaderComparisonSuiteTests) into a run
# folder, then diffs it against a baseline run when one is given.
#
#   Scripts/shader-compare.sh <run folder> [--baseline <run folder>] [--library <folder>]
#                             [--scenes <list file>] [--derived-data <folder>] [--no-renders]
#
# Needs OWE_ASSETS and a test build (`xcodebuild build-for-testing`, see Scripts/ci-local.sh) in
# the derived data folder (default build/shader-compare/DerivedData). The library is only read.
# The scene list has one scene folder per line. Renders of library wallpapers are for the metrics:
# compare them by the numbers in renders.json.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=""; BASELINE=""; LIBRARY=""; SCENES=""; DERIVED="build/shader-compare/DerivedData"; RENDERS=1
while (( $# )); do
  case "$1" in
    --baseline) BASELINE=$2; shift 2 ;;
    --library) LIBRARY=$2; shift 2 ;;
    --scenes) SCENES=$2; shift 2 ;;
    --derived-data) DERIVED=$2; shift 2 ;;
    --no-renders) RENDERS=0; shift ;;
    *) OUT=$1; shift ;;
  esac
done
[[ -n "$OUT" ]] || { echo "usage: $0 <run folder> [--baseline <run>] [--library <folder>] [--scenes <file>]" >&2; exit 2; }
[[ -d "${OWE_ASSETS:-}" ]] || { echo "OWE_ASSETS is not a folder" >&2; exit 2; }
runs=("$DERIVED"/Build/Products/*.xctestrun(N))
(( ${#runs} )) || { echo "No test build in $DERIVED" >&2; exit 1; }
mkdir -p "$OUT"
rm -rf "$OUT/results.xcresult"

tests=(-only-testing:OpenWallpaperEngineTests/ShaderComparisonSuiteTests/testTranslateCorpus)
(( RENDERS )) && [[ -n "$SCENES" ]] && tests+=(-only-testing:OpenWallpaperEngineTests/ShaderComparisonSuiteTests/testRenderScenes)

TEST_RUNNER_OWE_ASSETS="$OWE_ASSETS" \
TEST_RUNNER_OWE_SHADER_COMPARE_OUT="$(cd "$OUT" && pwd)" \
TEST_RUNNER_OWE_SHADER_COMPARE_LIBRARY="$LIBRARY" \
TEST_RUNNER_OWE_SHADER_COMPARE_SCENES="$SCENES" \
TEST_RUNNER_OWE_SHADER_COMPARE_BASELINE="$BASELINE" \
xcodebuild test-without-building -xctestrun "${runs[1]}" -destination platform=macOS \
  -resultBundlePath "$OUT/results.xcresult" "${tests[@]}" > "$OUT/xcodebuild.log" 2>&1 \
  || { grep -E "error:|failed" "$OUT/xcodebuild.log" | head -20; echo "Test run failed: $OUT/xcodebuild.log" >&2; exit 1; }

if [[ -n "$BASELINE" ]]; then
  python3 Scripts/shader-compare-diff.py "$BASELINE" "$OUT" -o "$OUT/diff.json"
fi
