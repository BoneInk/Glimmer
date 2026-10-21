#!/bin/bash
# Tests release-version.sh: bash Scripts/release/test-release-version.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-version.sh
source "$here/release-version.sh"
set +e

failures=0
expect() { # expect <tag> <expected output, lines joined by spaces>
  local got
  got="$(parse_release_tag "$1" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
  if [ "$got" != "$2" ]; then
    echo "FAIL $1"; echo "  expected: $2"; echo "  got:      $got"; failures=$((failures + 1))
  fi
}
reject() {
  if parse_release_tag "$1" >/dev/null 2>&1; then echo "FAIL accepted '$1'"; failures=$((failures + 1)); fi
}

expect v1.0.0 "tag=v1.0.0 version=1.0.0 label=1.0.0 prerelease=false channel= title=1.0.0"
expect v1.0.0-beta.1 "tag=v1.0.0-beta.1 version=1.0.0 label=1.0.0-beta.1 prerelease=true channel=beta title=1.0.0 Beta 1"
expect v2.10.3-alpha.0 "tag=v2.10.3-alpha.0 version=2.10.3 label=2.10.3-alpha.0 prerelease=true channel=beta title=2.10.3 Alpha 0"
expect v1.0.0-rc.12 "tag=v1.0.0-rc.12 version=1.0.0 label=1.0.0-rc.12 prerelease=true channel=beta title=1.0.0 RC 12"
for bad in "" 1.0.0 v1 v1.0 v1.0.0.0 v01.0.0 v1.0.0- v1.0.0-beta v1.0.0-beta. v1.0.0-preview.1 \
           v1.0.0-Beta.1 v1.0.0-beta.1.2 v1.0.0-beta.01 "v1.0.0 " "v1.0.0-beta.1;rm" v1.0.x; do
  reject "$bad"
done

# The command-line form.
out="$(bash "$here/release-version.sh" v3.2.1)" || { echo "FAIL command line"; failures=$((failures + 1)); }
[[ "$out" == *"version=3.2.1"* ]] || { echo "FAIL command line output"; failures=$((failures + 1)); }
if bash "$here/release-version.sh" nope 2>/dev/null; then echo "FAIL command line accepted 'nope'"; failures=$((failures + 1)); fi

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "release-version: all tests passed"
