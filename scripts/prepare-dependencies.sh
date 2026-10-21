#!/bin/bash
# Prepare project-private build dependencies without changing global tools.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-prepare}"
if [ "$#" -gt 1 ] || { [ "$MODE" != prepare ] && [ "$MODE" != --verify ]; }; then
  echo "Usage: scripts/prepare-dependencies.sh [--verify]" >&2
  exit 2
fi
SDK_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/Workers/SteamContent/sdk-pin.json")"
SDK="$ROOT/.tools/dotnet-$SDK_VERSION"
if [ ! -x "$SDK/dotnet" ]; then
  if [ "$MODE" = --verify ]; then
    echo "Missing project-private .NET SDK; run scripts/prepare-dependencies.sh" >&2
    exit 1
  fi
  bash "$ROOT/scripts/install-steam-content-sdk.sh"
fi
DOTNET_ROOT="$SDK" DOTNET_CLI_HOME="$ROOT/.tools/steam-content-cli" \
  DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 "$SDK/dotnet" --version | \
  python3 -c 'import sys; actual=sys.stdin.read().strip(); expected=sys.argv[1]; sys.exit(0 if actual == expected else "Unexpected .NET SDK: " + actual)' "$SDK_VERSION"
python3 - "$ROOT" "$MODE" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import urllib.request

root = Path(sys.argv[1])
pin = json.loads((root / 'Workers/SteamContent/source-pin.json').read_text())
destination = root / '.tools' / pin['archive']

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()

if destination.exists():
    if digest(destination) != pin['sha256']:
        raise SystemExit('SteamKit2 source checksum mismatch; existing archive left untouched')
elif sys.argv[2] == '--verify':
    raise SystemExit('Missing SteamKit2 source archive; run scripts/prepare-dependencies.sh')
else:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix='steamkit-source-', suffix='.part', dir=destination.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'wb') as output, urllib.request.urlopen(pin['url'], timeout=120) as response:
            while block := response.read(1024 * 1024):
                output.write(block)
        if digest(temporary) != pin['sha256']:
            raise SystemExit('SteamKit2 source checksum mismatch; refusing installation')
        temporary.replace(destination)
    finally:
        temporary.unlink(missing_ok=True)
print('Verified project-private .NET SDK and pinned SteamKit2 source archive')
PY
