#!/bin/bash
# Downloads the Wallpaper Engine files the app and the asset-dependent tests use (`assets/`, the UI
# strings `locale/ui_*.json`, `projects/defaultprojects/`, New Wallpaper's `projects/templates/` and
# the script editor's snippets `ui/dist/monaco/snippets/*.js`) from Steam with DepotDownloader,
# logged in as the CI Steam account that owns Wallpaper Engine (app 431960). The one entry point
# for CI and local test runs; see docs/ci-assets.md.
#
#   Scripts/fetch-we-assets.sh [--dry-run] [--force] [destination]
#   Scripts/fetch-we-assets.sh --build-id      prints the current public build id and exits
#
# The destination (argument, else $OWE_WE_ASSETS_DIR, else ~/Library/Caches/owe-we-assets) is laid out like a WE install, so
# OWE_ASSETS / TEST_RUNNER_OWE_ASSETS accept it. Nothing is downloaded when its `.build` matches
# the current build and its `.filelist` the files this script asks for. Credentials:
# OWE_CI_STEAM_USER, OWE_CI_STEAM_PASSWORD and OWE_CI_STEAM_SHARED_SECRET, else (macOS) the login Keychain items of service `owe-ci-steam`,
# accounts `user`, `password` and `shared-secret`. Secrets and Steam Guard codes are never printed.
#
# Exit codes: 0 done or up to date, 2 usage, 3 missing credentials, 4 login failed (password or
# Steam Guard), 5 rate limited by Steam, 6 the account doesn't own Wallpaper Engine, 7 download
# failed, 8 DepotDownloader couldn't be fetched or verified, 9 build id lookup failed (--build-id).

set -euo pipefail

APP_ID=431960
DD_VERSION=3.4.0
DD_TAG="DepotDownloader_$DD_VERSION"
DD_SHA256_macos_arm64=60e80c7c496f3f9a079cd3c62036b35d088c27bc0149baf38f009eb57a52f6a5
DD_SHA256_macos_x64=  # not pinned: only Apple silicon Macs are supported
DD_SHA256_linux_x64=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53
BUILD_ID_URL="https://api.steamcmd.net/v1/info/$APP_ID"
KEYCHAIN_SERVICE=owe-ci-steam
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

E_USAGE=2 E_CREDENTIALS=3 E_LOGIN=4 E_RATE=5 E_NOT_OWNED=6 E_DOWNLOAD=7 E_TOOL=8 E_BUILD_ID=9

fail() { local status=$1; shift; echo "error: $*" >&2; [[ -z "${GITHUB_ACTIONS:-}" ]] || echo "::error::$*"; exit "$status"; }
mask() { [[ -z "${GITHUB_ACTIONS:-}" || -z "$1" ]] || echo "::add-mask::$1"; }

DRY_RUN=0 FORCE=0 BUILD_ID_ONLY=0 DEST=""
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --build-id) BUILD_ID_ONLY=1 ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) fail $E_USAGE "unknown option $1" ;;
        *) [[ -z "$DEST" ]] || fail $E_USAGE "one destination only"; DEST="$1" ;;
    esac
    shift
done

if [[ "$(uname -s)" == Darwin ]]; then
    DEFAULT_DEST="$HOME/Library/Caches/owe-we-assets"
    DEFAULT_TOOLS="$HOME/Library/Caches/owe-tools"
else
    DEFAULT_DEST="${XDG_CACHE_HOME:-$HOME/.cache}/owe-we-assets"
    DEFAULT_TOOLS="${XDG_CACHE_HOME:-$HOME/.cache}/owe-tools"
fi
DEST="${DEST:-${OWE_WE_ASSETS_DIR:-$DEFAULT_DEST}}"
TOOLS="${OWE_TOOLS_DIR:-$DEFAULT_TOOLS}"

# The current public build, keyless (api.steamcmd.net mirrors Steam's PICS app info). Empty when
# the lookup fails or returns anything but digits: the download then runs, and DepotDownloader
# resolves the build itself.
build_id() {
    local id
    id=$(curl -fsSL --retry 3 --max-time 20 "$BUILD_ID_URL" 2>/dev/null | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["data"][sys.argv[1]]["depots"]["branches"]["public"]["buildid"])
except Exception:
    pass' "$APP_ID" || true)
    [[ "$id" =~ ^[0-9]+$ ]] && echo "$id" || true
}

BUILD="$(build_id)"
if ((BUILD_ID_ONLY)); then
    [[ -n "$BUILD" ]] || fail $E_BUILD_ID "couldn't read the current Wallpaper Engine build id from $BUILD_ID_URL"
    echo "$BUILD"; exit 0
fi

# What DepotDownloader downloads (`-filelist`).
FILELIST=$'regex:^assets/\nregex:^locale/ui_.*\\.json$\nregex:^projects/defaultprojects/\nregex:^projects/templates/\nregex:^ui/dist/monaco/snippets/[^/]*\\.js$'

HAVE=""; [[ -f "$DEST/.build" ]] && HAVE="$(cat "$DEST/.build")"
# A folder fetched with another file list (an older copy of this script) is downloaded again.
HAVE_FILES=""; [[ -f "$DEST/.filelist" ]] && HAVE_FILES="$(cat "$DEST/.filelist")"
echo "destination: $DEST"
echo "current build: ${BUILD:-unknown}; cached build: ${HAVE:-none}"
if ((!FORCE)) && [[ -n "$BUILD" && "$BUILD" == "$HAVE" && "$HAVE_FILES" == "$FILELIST" && -d "$DEST/assets/shaders" ]]; then
    echo "up to date"; exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) PLATFORM=macos-arm64 SHA="$DD_SHA256_macos_arm64" ;;
    Darwin-x86_64) PLATFORM=macos-x64 SHA="$DD_SHA256_macos_x64" ;;
    Linux-x86_64) PLATFORM=linux-x64 SHA="$DD_SHA256_linux_x64" ;;
    *) fail $E_TOOL "no DepotDownloader build for $(uname -s) $(uname -m)" ;;
esac
DD_DIR="$TOOLS/depotdownloader/$DD_VERSION-$PLATFORM"
DD="$DD_DIR/DepotDownloader"
DD_URL="https://github.com/SteamRE/DepotDownloader/releases/download/$DD_TAG/DepotDownloader-$PLATFORM.zip"

if ((DRY_RUN)); then
    echo "dry run; would:"
    [[ -x "$DD" ]] && echo "  use DepotDownloader $DD_VERSION at $DD" \
        || echo "  fetch $DD_URL (sha256 ${SHA:-UNPINNED}) into $DD_DIR"
    echo "  read credentials from ${OWE_CI_STEAM_USER:+the environment}${OWE_CI_STEAM_USER:-the login Keychain (service $KEYCHAIN_SERVICE)}"
    echo "  run DepotDownloader -app $APP_ID -os windows -osarch 64 -no-mobile -dir $DEST -filelist <file> with:"
    sed 's/^/    /' <<<"$FILELIST"
    echo "  write $DEST/.build, $DEST/.filelist and $DEST/.owe-assets-info.json"
    exit 0
fi

# DepotDownloader, pinned and verified.
if [[ ! -x "$DD" ]]; then
    [[ -n "$SHA" ]] || fail $E_TOOL "no pinned DepotDownloader hash for $PLATFORM"
    echo "fetching DepotDownloader $DD_VERSION ($PLATFORM)"
    mkdir -p "$DD_DIR"
    zip="$DD_DIR.zip"
    curl -fsSL --retry 3 -o "$zip" "$DD_URL" || fail $E_TOOL "couldn't download $DD_URL"
    got="$(shasum -a 256 "$zip" 2>/dev/null || sha256sum "$zip")"; got="${got%% *}"
    [[ "$got" == "$SHA" ]] || { rm -f "$zip"; fail $E_TOOL "DepotDownloader checksum mismatch (got $got)"; }
    unzip -o -q "$zip" -d "$DD_DIR" && rm -f "$zip"
    chmod +x "$DD"
    [[ "$(uname -s)" != Darwin ]] || xattr -dr com.apple.quarantine "$DD_DIR" 2>/dev/null || true
fi

# Credentials: environment first, then the macOS login Keychain.
keychain() { [[ "$(uname -s)" == Darwin ]] && security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$1" -w 2>/dev/null || true; }
STEAM_USER="${OWE_CI_STEAM_USER:-$(keychain user)}"
STEAM_PASSWORD="${OWE_CI_STEAM_PASSWORD:-$(keychain password)}"
STEAM_SECRET="${OWE_CI_STEAM_SHARED_SECRET:-$(keychain shared-secret)}"
missing=()
[[ -n "$STEAM_USER" ]] || missing+=(user)
[[ -n "$STEAM_PASSWORD" ]] || missing+=(password)
[[ -n "$STEAM_SECRET" ]] || missing+=(shared-secret)
((${#missing[@]} == 0)) || fail $E_CREDENTIALS "missing Steam credentials: ${missing[*]} (set OWE_CI_STEAM_USER, OWE_CI_STEAM_PASSWORD and OWE_CI_STEAM_SHARED_SECRET, or add Keychain items of service $KEYCHAIN_SERVICE; see docs/ci-assets.md)"
mask "$STEAM_USER"; mask "$STEAM_PASSWORD"; mask "$STEAM_SECRET"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf '%s\n' "$FILELIST" > "$WORK/filelist.txt"
LOG="$WORK/depotdownloader.log"

# The Steam Guard code, made just before it's needed: one in its last seconds waits for the next.
steam_guard_code() {
    local left
    left=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import steam_totp; print(steam_totp.seconds_left())' "$HERE")
    ((left > 5)) || sleep "$left"
    OWE_CI_STEAM_SHARED_SECRET="$STEAM_SECRET" python3 "$HERE/steam_totp.py"
}
CODE="$(steam_guard_code)" || fail $E_CREDENTIALS "the Steam Guard shared secret isn't valid base64"
mask "$CODE"

# DepotDownloader reads the password, then the Steam Guard code, from redirected stdin, so
# neither is on its command line. -no-mobile asks for a code instead of an app confirmation.
mkdir -p "$DEST"
set +e
printf '%s\n%s\n' "$STEAM_PASSWORD" "$CODE" | "$DD" \
    -app "$APP_ID" -os windows -osarch 64 -no-mobile \
    -username "$STEAM_USER" -dir "$DEST" -filelist "$WORK/filelist.txt" 2>&1 \
    | grep -v -e 'Enter account password' -e 'STEAM GUARD! Please enter' | tee "$LOG"
status=${PIPESTATUS[1]}
set -e
unset STEAM_PASSWORD CODE

if grep -qE 'RateLimitExceeded|AccountLoginDeniedThrottle|TooManyRequests' "$LOG"; then
    fail $E_RATE "Steam is rate limiting this account's logins; wait (often 30-60 min) and retry"
elif grep -qE 'Unable to login to Steam3|Failed to authenticate with Steam|InvalidPassword|previous 2-factor auth code|TwoFactorCodeMismatch|Access token was rejected' "$LOG"; then
    fail $E_LOGIN "Steam login failed (wrong password or Steam Guard shared secret, or the clock is off)"
elif grep -q 'is not available from this account' "$LOG"; then
    fail $E_NOT_OWNED "the Steam account doesn't own Wallpaper Engine (app $APP_ID)"
elif ((status != 0)) || [[ ! -d "$DEST/assets/shaders" || ! -d "$DEST/assets/effects" ]]; then
    fail $E_DOWNLOAD "DepotDownloader failed (exit $status); see the log above"
fi

# Keep .DepotDownloader/depot.config (tiny; lets the next run download only what changed), drop
# its staging files.
rm -rf "$DEST/.DepotDownloader/staging"
[[ -n "$BUILD" ]] || BUILD="$(build_id)"
DEFAULTS=()
if [[ -d "$DEST/projects/defaultprojects" ]]; then
    while IFS= read -r name; do DEFAULTS+=("$name"); done < <(find "$DEST/projects/defaultprojects" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
fi
# The same format WallpaperEngineAssetsCache.writeInfo writes.
python3 - "$DEST/.owe-assets-info.json" "$BUILD" "${DEFAULTS[@]+"${DEFAULTS[@]}"}" <<'PY'
import datetime, json, sys
path, build, *defaults = sys.argv[1:]
info = {"origin": "steam",
        "installedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
if build:
    info["steamBuildID"] = build
if defaults:
    info["defaultProjects"] = defaults
with open(path, "w") as f:
    f.write(json.dumps(info, indent=2, sort_keys=True).replace('": ', '" : ') + "\n")
PY
printf '%s\n' "$BUILD" > "$DEST/.build"
printf '%s\n' "$FILELIST" > "$DEST/.filelist"
echo "done: build ${BUILD:-unknown}, $(find "$DEST/assets" "$DEST/locale" "$DEST/projects" "$DEST/ui" -type f 2>/dev/null | wc -l | tr -d ' ') files in $DEST"
