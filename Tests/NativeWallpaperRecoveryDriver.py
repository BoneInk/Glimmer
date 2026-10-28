"""Run a signed sandbox probe and terminate only WebKit processes it owns.

The probe reports its WKWebView's content PID over stderr. Host-side termination
exercises WebKit's real process-loss callback without widening sandbox rights.
No provider registration or system wallpaper changes are performed.
"""
import json
import os
import pathlib
import selectors
import signal
import subprocess
import sys
import time


def run(binary, fixture, output):
    output = pathlib.Path(output)
    process = subprocess.Popen([binary, '--isolated-live-probe', fixture],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    streams = selectors.DefaultSelector()
    streams.register(process.stdout, selectors.EVENT_READ, 'stdout')
    streams.register(process.stderr, selectors.EVENT_READ, 'stderr')
    captured = {'stdout': bytearray(), 'stderr': bytearray()}
    pending = bytearray()
    killed = []
    deadline = time.monotonic() + 150
    try:
        while streams.get_map():
            if time.monotonic() > deadline:
                raise TimeoutError('Native wallpaper recovery probe timed out')
            for key, _ in streams.select(timeout=1):
                data = os.read(key.fileobj.fileno(), 65536)
                if not data:
                    streams.unregister(key.fileobj)
                    continue
                captured[key.data].extend(data)
                if key.data != 'stderr':
                    continue
                pending.extend(data)
                while b'\n' in pending:
                    line, _, remaining = pending.partition(b'\n')
                    pending[:] = remaining
                    prefix = b'GW_RECOVERY_KILL_WEB_PROCESS='
                    if not line.startswith(prefix):
                        continue
                    pid = int(line[len(prefix):])
                    assert pid > 1 and pid not in (os.getpid(), process.pid) and pid not in killed
                    identity = subprocess.check_output(
                        ['/bin/ps', '-p', str(pid), '-o', 'uid=,comm='], text=True).strip().split(maxsplit=1)
                    assert len(identity) == 2 and int(identity[0]) == os.getuid(), identity
                    assert pathlib.Path(identity[1]).name.startswith('com.apple.WebKit.WebContent'), identity
                    os.kill(pid, signal.SIGKILL)
                    killed.append(pid)
        code = process.wait(timeout=5)
        value = json.loads(captured['stdout'])
        assert code == 0 and value['success'] and value['sandboxActive'], value
        assert not value['systemWallpaperModified'], value
        if value['kind'] == 'web':
            assert len(killed) == 3, killed
        print(json.dumps({'kind': value['kind'], 'success': True, 'terminatedOwnedWebProcesses': len(killed)}))
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        streams.close()
        output.with_suffix('.json').write_bytes(captured['stdout'])
        output.with_suffix('.stderr').write_bytes(captured['stderr'])
        output.with_suffix('.driver.json').write_text(json.dumps({'terminatedOwnedWebProcesses': killed}, indent=2))


if __name__ == '__main__':
    run(*sys.argv[1:])
