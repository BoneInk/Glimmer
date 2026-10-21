#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR=/Library/Developer/CommandLineTools python3 - "$root" <<'PY'
import hashlib,json,pathlib,sys,tarfile,urllib.request
root=pathlib.Path(sys.argv[1]);pin=json.loads((root/'Workers/SteamContent/sdk-pin.json').read_text())
archive=root/'.tools'/('dotnet-sdk-'+pin['version']+'.tar.gz'); destination=root/'.tools'/('dotnet-'+pin['version'])
archive.parent.mkdir(exist_ok=True)
if not archive.exists(): urllib.request.urlretrieve(pin['url'],archive)
h=hashlib.sha512()
with archive.open('rb') as f:
 for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
if h.hexdigest()!=pin['sha512']: raise SystemExit('Official SDK SHA512 mismatch; refusing extraction')
with tarfile.open(archive) as tar:
 for member in tar.getmembers():
  if member.name.startswith('/') or '..' in pathlib.PurePosixPath(member.name).parts: raise SystemExit('Unsafe archive member')
  if (member.issym() or member.islnk()) and (member.linkname.startswith('/') or '..' in pathlib.PurePosixPath(member.linkname).parts): raise SystemExit('Unsafe archive link')
 destination.mkdir(exist_ok=True)
 tar.extractall(destination)
print('Verified project-private SDK '+pin['version']+'; no global PATH or service changes')
PY
