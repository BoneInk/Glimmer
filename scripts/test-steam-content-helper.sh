#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/build-steam-content-helper.sh" >&2
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 "$root/Tests/SteamContent/transfer_probe.py" "$root/build/SteamContent/GlimmerSteamContent"
