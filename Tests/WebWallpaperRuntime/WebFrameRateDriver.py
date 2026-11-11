"""Real original 4K/60 Web wallpaper, owned native layer, no system changes."""
import json
import os
import pathlib
import select
import shutil
import subprocess
import sys
import tempfile
import time

producer, source, destination = map(pathlib.Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
parent = pathlib.Path('/Users/Shared/GlimmerNativeLockScreen') / str(os.getuid())
events = []
with tempfile.TemporaryDirectory(prefix='isolated-frame-rate-', dir=parent) as temporary:
    root = pathlib.Path(temporary)
    live = root/source.name
    shutil.copytree(source, live)
    recipe = json.loads((live/'recipe.json').read_text())
    (root/'config.json').write_text(json.dumps(dict(schemaVersion=2, assetID=recipe['assetID'], videoFileName='',
                                                   liveDirectoryName=live.name, gravity='fill', isMuted=True)))
    (root/'config.json').chmod(0o600)
    with (destination/'native-rate.stderr').open('w') as error:
        process = subprocess.Popen([str(producer), '--web-layer-producer', str(root)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=error, bufsize=0)
        pending = b''

        def receive():
            global pending
            deadline = time.monotonic()+40
            while time.monotonic()<deadline:
                try:
                    text = pending.decode().lstrip(); event, end = json.JSONDecoder().raw_decode(text)
                except (ValueError, UnicodeDecodeError):
                    pass
                else:
                    pending = text[end:].encode(); events.append(event)
                    (destination/'native-rate-events.json').write_text(json.dumps(events,indent=2))
                    if event.get('event')=='error': raise RuntimeError(event)
                    return event
                if select.select([process.stdout],[],[],.25)[0]:
                    data = os.read(process.stdout.fileno(),65536)
                    if not data: raise RuntimeError('producer exited')
                    pending += data
            raise TimeoutError('producer response timed out')

        def command(value):
            process.stdin.write((value+'\n').encode()); return receive()

        def observe(fps, seconds):
            time.sleep(3)
            rows=[command('metrics')]
            for _ in range(int(seconds/4)):
                time.sleep(4); rows.append(command('metrics'))
            first,last=rows[0]['value'],rows[-1]['value']; duration=(last['now']-first['now'])/1000
            raf=(last['raf']-first['raf'])/duration
            video=(last['videoFrames']-first['videoFrames'])/duration
            value=dict(target=fps,seconds=duration,raf=raf,videoFrameCounter=video,documentCount=last['documentCount'],
                       unchangedDocumentClock=last['now']>first['now'],snapshots=[r['snapshotCount'] for r in rows],
                       videoTime=last['videoTime'],duration=last['duration'])
            print(value,flush=True)
            assert fps*.85 <= raf <= fps+1.5, value
            assert 0 < video <= 62, value  # activity check, not a video decode-rate guarantee
            assert not last['videoPaused'] and last['videoWidth']==3840 and last['error']==0, last
            assert len(set(value['snapshots']))==1
            return value

        try:
            context=receive(); measurement=receive()
            assert context['event']=='context' and context['sandboxActive'] and not context['producerWindowOrdered']
            assert measurement['event']=='measurement'
            phases=[observe(30,32)]
            assert command('fps 15')['event']=='fps'
            phases.append(observe(15,32))
            assert command('fps 60')['event']=='fps'
            phases.append(observe(60,32))
            paused=command('media-pause')['value']
            assert command('fps 30')['event']=='fps'
            time.sleep(3)
            after=command('metrics')['value']
            assert after['videoPaused'] and abs(after['videoTime']-paused['videoTime'])<.1, (paused,after)
            assert len({p['documentCount'] for p in phases})==1 and phases[0]['duration']==phases[1]['duration']
            result=dict(success=True,phases=phases,pausedVideoStatePreserved=True,
                        originalResolutionPreserved=True,sameDocumentOnLiveChanges=True,noPeriodicSnapshots=True,nativeVideoUnchanged=True,
                        systemWallpaperModified=False,scope='signed isolated native Web layer; callback counters, not display scanout')
            (destination/'native-rate-summary.json').write_text(json.dumps(result,indent=2))
            command('stop');process.wait(timeout=5)
        finally:
            if process.poll() is None: process.terminate();process.wait(timeout=5)
