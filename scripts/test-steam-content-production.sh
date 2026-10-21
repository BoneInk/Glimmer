#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d /private/tmp/gw-steam-production-tests.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT
"$root/scripts/test-steam-content-session.sh" > "$fixture/session.json"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 "$root/Tests/SteamContent/production_cli_probe.py" "$root/build/SteamContent/GlimmerSteamContent" > "$fixture/cli.json"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 "$root/Tests/SteamContent/transfer_probe.py" "$root/build/SteamContent/GlimmerSteamContent" > "$fixture/transport.json"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 - "$fixture" "$root" <<'PY'
import hashlib,json,pathlib,sys
folder=pathlib.Path(sys.argv[1]);root=pathlib.Path(sys.argv[2]);groups={name:json.loads((folder/(name+'.json')).read_text()) for name in ['session','cli','transport']}
published=root/'build/SteamContent/GlimmerSteamContent.dll';tested=root/'Tests/SteamContent/bin/Release/net10.0/osx-arm64/GlimmerSteamContent.dll'
assert hashlib.sha256(published.read_bytes()).digest()==hashlib.sha256(tested.read_bytes()).digest(), 'test assembly differs from published helper'
print(json.dumps({'passed':sum(g['passed'] for g in groups.values()),'groups':groups,'sameManagedAssemblyVerified':True,'managedSHA256':hashlib.sha256(published.read_bytes()).hexdigest(),'scope':'controlled auth/session + real SDK loopback transfer + production invalid-command gates; NO real Steam login or Workshop network'},ensure_ascii=False,indent=2))
PY
