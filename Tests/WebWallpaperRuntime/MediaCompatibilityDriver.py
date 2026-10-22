"""Exercise actual native surfaces; fixture clips and synthetic state changes only."""
import concurrent.futures
import json
import os
import pathlib
import select
import subprocess
import sys
import time

producer, output = sys.argv[1:]
output = pathlib.Path(output).resolve()
fixtures = json.loads((output / 'fixtures.json').read_text())
if os.environ.get('GW_MEDIA_MATRIX_CASES'):
    selected = set(os.environ['GW_MEDIA_MATRIX_CASES'].split(','))
    fixtures = [case for case in fixtures if case['name'] in selected]


def run(case):
    name = case['name']
    events = []
    result = dict(name=name, generated=case['generated'], title=case.get('title'), scope='isolated native remote layer; not password-screen visual acceptance')
    if not case['generated']:
        return dict(result, status='fixture_generation_failed', error=case.get('error'))
    stderr = (output / (name + '.stderr')).open('w')
    p = subprocess.Popen([producer, '--web-layer-producer', case['directory']], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=stderr, bufsize=0)
    pending = b''

    def receive(timeout=40):
        nonlocal pending
        deadline = time.monotonic() + timeout
        decoder = json.JSONDecoder()
        while True:
            try:
                content = pending.decode('utf-8').lstrip()
                event, end = decoder.raw_decode(content)
            except (ValueError, UnicodeDecodeError):
                pass
            else:
                # Startup failures use pretty-printed JSON; normal command replies
                # use one JSON object per line. Parse complete objects in both cases.
                pending = content[end:].encode('utf-8')
                events.append(event)
                if event.get('event') == 'error':
                    raise RuntimeError(event.get('error'))
                return event
            if time.monotonic() >= deadline:
                raise TimeoutError('Native producer response timed out: '+repr(pending[:200]))
            if not select.select([p.stdout], [], [], min(.25, max(.01, deadline-time.monotonic())))[0]:
                continue
            data = os.read(p.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError('Native producer exited: '+repr(pending[:200]))
            pending += data

    def command(value):
        p.stdin.write((value+'\n').encode())
        return receive()

    def observe(seconds):
        rows = [command('metrics')]
        for _ in range(2):
            time.sleep(seconds/2)
            rows.append(command('metrics'))
        first, last = rows[0]['value'], rows[-1]['value']
        duration = (last['now']-first['now'])/1000
        data = dict(seconds=duration, rafCallbacksPerSecond=(last['raf']-first['raf'])/max(.001,duration),
                    clockCurrent=True, snapshotsStable=len({r['snapshotCount'] for r in rows})==1,
                    pageAudioMuted=all(r['value']['pageAudioMuted'] for r in rows), samples=[r['value'] for r in rows])
        if not case.get('sourceProject'):
            data['clockCurrent'] = all(abs(float(r['value']['clock'])-r['value']['wall'])<1500 for r in rows)
        if case['expectVideo']:
            start, end = first.get('fixture') or {}, last.get('fixture') or {}
            loops = end.get('loops',0)-start.get('loops',0)
            frames = end.get('presented',0)-start.get('presented',0)
            data.update(nativeLoops=loops, presentedFrames=frames,
                        playing=last['videoWidth']>0 and not last['videoPaused'] and last['error']==0,
                        continuousLoop=loops>=2 and frames>=4)
        else:
            data.update(continuousAnimation=last['raf']-first['raf']>=10)
            if name == 'html-webgl-clock':
                pixels=[(r['value'].get('fixture') or {}).get('pixel') for r in rows]
                data['webglPixelsChange']=all(x for x in pixels) and len({tuple(x) for x in pixels if x})>=2
        return data

    try:
        context = receive()
        result['context'] = context
        assert context['event']=='context' and context['sandboxActive'] and not context['producerWindowOrdered'], context
        benchmark = receive()
        assert benchmark['event']=='measurement', benchmark
        result['initialBenchmark'] = benchmark
        if case['expectVideo']:
            response = command('media-response')
            result['resourceResponse'] = json.loads(response['value'])
            first = benchmark['value']['end']
            result['audioTracksSeen'] = len(first['audioTracks']) if first.get('audioTracks') is not None else None
            result['videoTracksSeen'] = len(first['videoTracks']) if first.get('videoTracks') is not None else None
            result['sourcePreserved'] = result['resourceResponse'].get('sha256')==case['sourceSHA256']
            result['containerAdapted'] = result['resourceResponse']['type']=='video/mp4' and case['extension']=='webm'
            if case.get('audio'):
                result['audioTracksPreserved'] = result['sourcePreserved'] and result['audioTracksSeen']==len(case['audio'])
            if case.get('alpha'):
                alpha = (first.get('fixture') or {}).get('alpha')
                result['alphaReference'] = case['referenceAlpha']
                result['alphaSeen'] = alpha
                result['alphaPreserved'] = alpha is not None and all(abs(a-b)<=4 for a,b in zip(alpha,case['referenceAlpha']))
        phases = result['phases'] = {}
        phases['initial'] = observe(6)
        assert command('reload')['event']=='reloaded'
        phases['reload'] = observe(4)
        assert command('pause')['event']=='paused'
        time.sleep(.15)
        resumed = command('resume')
        assert resumed['event']=='resumed'
        result['contextRetainedAfterResume'] = resumed['value']['contextID']==context['contextID']
        phases['resume'] = observe(4)
        assert command('sleep')['event']=='sleeping'
        awake = command('wake')
        assert awake['event']=='awake'
        result['contextRetainedAfterWake'] = awake['value']['contextID']==context['contextID']
        phases['wake'] = observe(4)
        result['phases'] = phases
        key = 'continuousLoop' if case['expectVideo'] else 'continuousAnimation'
        live = all(v[key] and v['clockCurrent'] and v['snapshotsStable'] and v['pageAudioMuted'] for v in phases.values())
        live = live and result['contextRetainedAfterResume'] and result['contextRetainedAfterWake']
        if name=='html-webgl-clock':
            live = live and all(v['webglPixelsChange'] for v in phases.values())
        if case.get('alpha'):
            live = live and result['alphaPreserved']
        if case.get('audio'):
            live = live and result['audioTracksPreserved']
        if case.get('videos')==2:
            live = live and result['sourcePreserved'] and result['videoTracksSeen']==2
        result['status'] = 'passed' if live else 'incompatible'
        command('stop')
        p.wait(timeout=10)
    except Exception as error:
        result.update(status='failed_to_load_or_resume', error=str(error))
    finally:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait(timeout=5)
        stderr.close()
        (output / (name+'-events.json')).write_text(json.dumps(events,indent=2))
        (output / (name+'-result.json')).write_text(json.dumps(result,indent=2))
        print(name,result['status'],result.get('error',''),flush=True)
    return result


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(run, fixtures))
(output / ('matrix-results-selected.json' if os.environ.get('GW_MEDIA_MATRIX_CASES') else 'matrix-results.json')).write_text(json.dumps(results,indent=2))
print(json.dumps(dict(cases=len(results),passed=sum(r['status']=='passed' for r in results),
                     incompatible=sum(r['status']=='incompatible' for r in results),
                     loadFailures=sum(r['status']=='failed_to_load_or_resume' for r in results))),flush=True)
