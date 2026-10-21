#!/bin/bash
# Parses a release tag: vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N. The same rules as
# OpenWallpaperEngine/Core/Updates/ReleaseVersion.swift.
#
#   Scripts/release/release-version.sh v1.0.0-beta.1
#
# prints key=value lines (append them to $GITHUB_OUTPUT):
#   tag=v1.0.0-beta.1   version=1.0.0 (MARKETING_VERSION)   label=1.0.0-beta.1 (the full version)
#   prerelease=true     channel=beta (the Sparkle channel; empty for a final release)
#   title=1.0.0 Beta 1  (for release names and the download button)
# and exits 1 with an error for anything else.
set -euo pipefail

parse_release_tag() {
  local tag="$1"
  if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(alpha|beta|rc)\.(0|[1-9][0-9]*))?$ ]]; then
    echo "error: tag '$tag' is not vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N" >&2
    return 1
  fi
  local version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  local stage="${BASH_REMATCH[5]}" number="${BASH_REMATCH[6]}"
  echo "tag=$tag"
  echo "version=$version"
  if [ -n "$stage" ]; then
    local name
    case "$stage" in
      alpha) name="Alpha" ;;
      beta) name="Beta" ;;
      rc) name="RC" ;;
    esac
    echo "label=$version-$stage.$number"
    echo "prerelease=true"
    echo "channel=beta"
    echo "title=$version $name $number"
  else
    echo "label=$version"
    echo "prerelease=false"
    echo "channel="
    echo "title=$version"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [ $# -eq 1 ] || { echo "usage: $0 <tag>" >&2; exit 2; }
  parse_release_tag "$1"
fi
