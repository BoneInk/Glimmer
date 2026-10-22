"""Explicit real-asset probe; uses an isolated config, never the system store."""
import datetime
import json
import pathlib
import subprocess
import sys
import time

producer, fixture, report = sys.argv[1:]
report = pathlib.Path(report)
events = []
with report.with_suffix('.stderr').open('w') as error:
    process = subprocess.Popen([producer, '--web-layer-producer', fixture], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=error, text=True, bufsize=1)

    def receive():
        line = process.stdout.readline()
        if not line:
            raise RuntimeError('Producer exited; see stderr')
        value = json.loads(line)
        events.append(value)
        report.write_text(json.dumps(events, ensure_ascii=False, indent=2))
        if value['event'] == 'error':
            raise RuntimeError(value.get('error'))
        return value

    def command(value):
        process.stdin.write(value + '\n')
        process.stdin.flush()
        return receive()

    def current_clock(value):
        # The explicit fixture enables this author's standard 24-hour clock.
        text = value['clock']
        now = value['wall'] / 1000
        return any(datetime.datetime.fromtimestamp(now - delta).strftime('%H:%M') in text
                   for delta in (0, 1))

    def loops(label):
        values = []
        snapshots = None
        deadline = time.monotonic() + 85
        while time.monotonic() < deadline:
            time.sleep(5)
            row = command('metrics')
            assert row['event'] == 'metrics', row
            value = row['value']
            if snapshots is None:
                snapshots = row['snapshotCount']
            assert row['snapshotCount'] == snapshots, 'Playback must not take periodic snapshots'
            values.append(value)
            count = sum(event['name'] == 'seeked' and event['media'] < .2 for event in value['events'])
            print(label, round(value['now'] / 1000, 2), round(value['videoTime'], 3), count,
                  value['videoFrames'], current_clock(value), flush=True)
            assert current_clock(value), value
            assert value['videoWidth'] == 3840 and not value['videoPaused'] and value['error'] == 0, value
            if count >= 3:
                assert value['videoFrames'] > values[0]['videoFrames']
                return values
        raise AssertionError('Three native loops did not finish')

    try:
        context, measurement = receive(), receive()
        assert context['event'] == 'context' and context['sandboxActive']
        assert measurement['event'] == 'measurement' and measurement['value']['snapshotsDuringPlayback'] == 0
        initial = loops('initial')
        assert command('pause')['event'] == 'paused'
        time.sleep(2)
        resumed = command('resume')
        assert resumed['event'] == 'resumed' and current_clock(resumed['value']), resumed
        after = loops('resumed')
        assert command('stop')['event'] == 'stopped'
        process.wait(timeout=10)
        assert process.returncode == 0
        result = dict(success=True, nativeLoopsBeforePause=3, nativeLoopsAfterResume=3,
                      authorClockCurrentBeforeAndAfterRecreation=True,
                      authorClockChangedOverMinuteBoundary=len({v['clock'] for v in initial + after}) >= 2,
                      initialRAF=(initial[-1]['raf']-initial[0]['raf'])/((initial[-1]['now']-initial[0]['now'])/1000),
                      resumedRAF=(after[-1]['raf']-after[0]['raf'])/((after[-1]['now']-after[0]['now'])/1000),
                      systemWallpaperModified=False)
        assert result['authorClockChangedOverMinuteBoundary'], result
        report.with_name(report.stem + '-summary.json').write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=10)
