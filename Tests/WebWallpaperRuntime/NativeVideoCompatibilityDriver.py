"""Read-only library validation through isolated, signed native video surfaces.

Checks startup, changing decoded frames, pause/resume, transport and release.
This short probe does not establish full-duration loops, source FPS or lock-screen visuals.
"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid

producer, evidence = sys.argv[1:]
evidence = pathlib.Path(evidence).resolve()
library_path = pathlib.Path.home() / 'Library/Application Support/Glimmer/library.json'
library_bytes = library_path.read_bytes()
items = [item for item in json.loads(library_bytes)['items'] if item.get('videoCodec')]
for case in json.loads((evidence / 'fixtures.json').read_text()):
    if case['name'] in ('mp4-h264', 'mp4-hevc'):
        folder = pathlib.Path(case['directory'])
        media = next(folder.glob('live-*/project/media.mp4'))
        items.append(dict(id=case['name'], title=case['name'], filePath=str(media), fileSizeBytes=media.stat().st_size))

parent = pathlib.Path('/Users/Shared/GlimmerNativeLockScreen') / str(os.getuid())
assert not parent.is_symlink() and parent.stat().st_uid == os.getuid() and parent.stat().st_mode & 0o077 == 0


def run(item):
    source = pathlib.Path(item['filePath'])
    result = dict(id=item['id'], title=item['title'], source=str(source), sourceFPS=item.get('frameRate'),
                  scope='short startup/pause/resume/transport/release; not full-duration loop, performance or password-screen acceptance')
    try:
        assert source.is_file() and not source.is_symlink(), 'Source missing or symlink'
        before = source.stat()
        with tempfile.TemporaryDirectory(prefix='isolated-native-video-', dir=parent) as temporary:
            folder = pathlib.Path(temporary)
            folder.chmod(0o700)
            aid = str(uuid.uuid4()).upper()
            media = folder / (aid + source.suffix.lower())
            shutil.copyfile(source, media)
            media.chmod(0o600)
            assert media.stat().st_size == before.st_size
            config = folder / 'config.json'
            config.write_text(json.dumps(dict(schemaVersion=1, assetID=aid, videoFileName=media.name,
                                             gravity='fill', isMuted=True)))
            config.chmod(0o600)
            process = subprocess.run([producer, '--isolated-video-probe', str(folder)], capture_output=True,
                                     text=True, timeout=25)
            (evidence / ('native-video-' + item['id'] + '.stderr')).write_text(process.stderr)
            value = json.loads(process.stdout)
            result['probe'] = value
            result['exitCode'] = process.returncode
            checks = ['started', 'remoteContextIDNonzero', 'desktopModePausesWithoutFrameLoop',
                      'previewOrLockedModeResumes', 'muted', 'sandboxActive', 'snapshotXPCTransportRoundTrip',
                      'remoteContextXPCTransportRoundTrip', 'stopReleasesPlayerContextAndBuffer']
            result['passed'] = process.returncode == 0 and all(value.get(key) is True for key in checks)
            result['passed'] = result['passed'] and value.get('decodedFramesEnqueued', 0) >= 8 and value.get('differentFrameSignatures', 0) >= 2
            assert value.get('systemWallpaperModified') is False
        after = source.stat()
        result['sourceMetadataUnchanged'] = (before.st_ino, before.st_size, before.st_mtime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns)
        result['bytes'] = before.st_size
        result['passed'] = result['passed'] and result['sourceMetadataUnchanged']
    except Exception as error:
        result.update(passed=False, error=str(error))
    (evidence / ('native-video-' + item['id'] + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(item['title'], result['passed'], result.get('error', ''), flush=True)
    return result


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(run, items))
report = dict(cases=results, passed=sum(row['passed'] for row in results), count=len(results),
              libraryUnchanged=hashlib.sha256(library_path.read_bytes()).digest() == hashlib.sha256(library_bytes).digest())
(evidence / 'native-video-results.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(dict(passed=report['passed'], count=report['count'], libraryUnchanged=report['libraryUnchanged'])), flush=True)
