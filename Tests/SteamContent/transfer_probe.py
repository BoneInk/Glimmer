#!/usr/bin/env python3
"""Original loopback fixtures only. Never logs into Steam or reads any user's profile."""
import atexit, hashlib, http.server, io, json, os, pathlib, queue, shutil, subprocess, sys, tempfile, threading, time, uuid, zipfile, zlib
BINARY = pathlib.Path(sys.argv[1]).resolve()
checks = []
children = []
def cleanup():
    for child in children:
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=3)
atexit.register(cleanup)
def check(value, name):
    if not value: raise AssertionError(name)
    checks.append(name)
class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler); self.routes = {}; self.hits = {}
        threading.Thread(target=self.serve_forever, daemon=True).start()
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)): return # expected cancellation
        super().handle_error(request, client_address)
    def route(self, name, bodies, slow=False, truncated=False):
        self.routes['/'+name] = (bodies, slow, truncated)
        return 'http://127.0.0.1:%d/%s' % (self.server_port, name)
class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *args): pass
    def do_GET(self):
        server = self.server; n = server.hits.get(self.path, 0); server.hits[self.path] = n+1
        bodies, slow, truncated = server.routes[self.path]; data = bodies[min(n, len(bodies)-1)]
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try:
            actual = data[:len(data)//2] if truncated and n == 0 else data
            for offset in range(0, len(actual), 4096):
                self.wfile.write(actual[offset:offset+4096]); self.wfile.flush()
                if slow: time.sleep(.02)
            if truncated and n == 0: self.close_connection = True
        except (BrokenPipeError, ConnectionResetError): pass
class Helper:
    def __init__(self, root=None, file_limit=None):
        argv=[str(BINARY)] + (['--fixture-root', str(root)] if root else [])
        if file_limit is not None:
            # Dedicated launcher execs only its own helper; no preexec_fn in the threaded HTTP process.
            code='import os,resource,signal,sys; resource.setrlimit(resource.RLIMIT_FSIZE,('+str(file_limit)+','+str(file_limit)+')); signal.signal(signal.SIGXFSZ,signal.SIG_IGN); os.execv(sys.argv[1],sys.argv[1:])'
            argv=[sys.executable,'-c',code]+argv
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(self.process)
        self.events=[]; self.q=queue.Queue()
        def read():
            for line in self.process.stdout:
                event=json.loads(line); self.events.append(event); self.q.put(event)
        threading.Thread(target=read,daemon=True).start()
        self.ready=self.wait('ready')
    def send(self, name, **kwargs):
        value=dict(v=1,commandName=name,requestID=str(uuid.uuid4()),**kwargs)
        self.process.stdin.write(json.dumps(value,separators=(',',':')).encode()+b'\n'); self.process.stdin.flush(); return value
    def wait(self, kind, timeout=8):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            event=self.q.get(timeout=max(.01,deadline-time.monotonic()))
            if event['kind']==kind: return event
            if event['kind'] in ('failed','rejected','fatal') and kind not in ('failed','rejected','fatal'): raise AssertionError((kind,event))
        raise AssertionError('missing '+kind)
    def finish(self):
        if self.process.poll() is None:
            self.send('shutdown'); self.wait('stopped'); self.process.wait(timeout=5)
        check(self.process.returncode==0, 'own helper exits cleanly')
def plan(data, url, job=None, epoch=1, file='resource.bin', **chunk_extra):
    return dict(jobID=job or str(uuid.uuid4()),epoch=epoch,appID=431960,publishedFileID='123',manifestID='456',depotID=431960,
        chunks=[dict(file=file,offset=0,length=len(data),sha1=hashlib.sha1(data).hexdigest(),url=url,**chunk_extra)])
def counters(event):
    return event['detail']['counters'] if 'counters' in event['detail'] else event['detail']
def run(h,p, terminal='transfer_complete'):
    h.send('fixture_transfer',plan=p); event=h.wait(terminal); return event

with tempfile.TemporaryDirectory(prefix='gw-content-') as temporary:
    root=pathlib.Path(temporary).resolve(); server=Server()
    h=Helper(root)
    check(h.ready['detail']['architecture']=='Arm64', 'actual native ARM64 process')
    check(h.ready['detail']['steamKitVersion'].startswith('3.4.'), 'real pinned SteamKit2 loaded')
    check(h.ready['detail']['productionWorkshopDownload'] is False, 'unwired production capability explicitly false')
    data=bytes((i*31+17)%256 for i in range(256*1024))
    url=server.route('slow',[data],slow=True); p=plan(data,url)
    h.send('fixture_transfer',plan=p); progress=h.wait('progress')
    check(int(progress['detail']['receivedPayloadBytes'])>0 and progress['detail']['downloadedVerifiedBytes']=='0','received bytes observable before chunk completion')
    complete=h.wait('transfer_complete'); c=counters(complete)
    check(c['logicalTotalBytes']==str(len(data)) and c['downloadedVerifiedBytes']==str(len(data)),'logical completion uses verified bytes')
    check(c['receivedPayloadBytes']==str(len(data)) and c['successfulCompressedPayloadBytes']==str(len(data)),'exact HTTP body and accepted payload counters')
    target=root/p['jobID']/p['manifestID']/'resource.bin'
    check(target.read_bytes()==data,'actual disk content equals fixture')
    check(target.stat().st_mode & 0o777 == 0o600,'Darwin arm64 variadic ABI shim creates private mode0600')
    check(all(isinstance(v,str) for v in c.values()),'all byte counters lossless decimal strings')
    check(not any('http://' in json.dumps(e) or str(root) in json.dumps(e) for e in h.events),'events contain no URLs/local paths')
    seq=[e['seq'] for e in h.events]
    check(seq==sorted(set(seq)) and len(set(e['sessionNonce'] for e in h.events))==1,'monotonic sequence and per-process nonce')
    time.sleep(.02)
    p['epoch']=2; reuse=run(h,p); c=counters(reuse)
    check(c['reusedVerifiedBytes']==str(len(data)) and c['receivedPayloadBytes']=='0' and c['downloadedVerifiedBytes']=='0','resume revalidates full correct chunk without network')
    check(server.hits['/slow']==1,'verified reuse performs no HTTP')
    target.write_bytes(b'\0'*len(data)); p['epoch']=3; fresh=run(h,p); c=counters(fresh)
    check(c['reusedVerifiedBytes']=='0' and c['downloadedVerifiedBytes']==str(len(data)),'same-size preallocation/corruption never counts reused')
    h.send('fixture_transfer',plan=p); rejection=h.wait('rejected')
    check(rejection['detail']['reason']=='stale_epoch','same epoch cannot replay a completed job')
    bad=bytes([data[0]^1])+data[1:]; url=server.route('retry',[bad,bad,data]); p=plan(data,url)
    e=run(h,p); c=counters(e)
    check(server.hits['/retry']==3 and c['receivedPayloadBytes']==str(len(data)*3),'failed checksum payload counted as received across retries')
    check(c['downloadedVerifiedBytes']==str(len(data)) and c['successfulCompressedPayloadBytes']==str(len(data)),'retry success counted once only after verification/write')
    url=server.route('truncate',[data,data],truncated=True); e=run(h,plan(data,url)); c=counters(e)
    check(int(c['receivedPayloadBytes'])>=len(data) and server.hits['/truncate']==2,'truncated transfer retried without false success')
    url=server.route('nevervalid',[bad]); e=run(h,plan(data,url), 'failed'); c=counters(e)
    check(c['downloadedVerifiedBytes']=='0' and c['reusedVerifiedBytes']=='0','exhausted checksum failure has zero logical completion')
    # A genuine SteamPipe-compatible encrypted ZIP fixture generated from original data. OpenSSL only
    # encrypts our deterministic bytes; no downloaded project/third-party source is used.
    zipped=io.BytesIO()
    with zipfile.ZipFile(zipped,'w',compression=zipfile.ZIP_DEFLATED) as archive: archive.writestr('chunk',data)
    key=bytes(range(32)); iv=bytes(range(16,32))
    def aes(mode, payload, extra):
        return subprocess.run(['/usr/bin/openssl','enc',mode,'-K',key.hex()]+extra,input=payload,stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True).stdout
    encrypted=aes('-aes-256-ecb',iv,['-nopad'])+aes('-aes-256-cbc',zipped.getvalue(),['-iv',iv.hex()])
    url=server.route('encrypted',[encrypted]); p=plan(data,url,compressedLength=len(encrypted),depotKey=key.hex(),adler32=zlib.adler32(data,0)&0xffffffff)
    e=run(h,p); c=counters(e)
    check(c['receivedPayloadBytes']==str(len(encrypted)) and c['downloadedVerifiedBytes']==str(len(data)),'real SteamKit decrypt/decompress verifies distinct compressed/uncompressed bytes')
    check((root/p['jobID']/p['manifestID']/'resource.bin').read_bytes()==data,'SteamKit decrypted content persisted exactly')
    p=plan(data,server.route('writefail',[data])); d=root/p['jobID']/p['manifestID']; d.mkdir(parents=True); f=d/'resource.bin'; f.write_bytes(b''); f.chmod(0o400)
    e=run(h,p,'failed'); check(counters(e)['downloadedVerifiedBytes']=='0' and server.hits.get('/writefail',0)==0,'unwritable destination cannot advertise content completion')
    f.chmod(0o600)
    limited=Helper(root/'limited',file_limit=4096)
    p=plan(data,server.route('disklimit',[data])); e=run(limited,p,'failed'); c=counters(e)
    check(c['receivedPayloadBytes']==str(len(data)) and c['downloadedVerifiedBytes']=='0','actual POSIX write failure AFTER validated receive never counts verified')
    check(not any(x['kind']=='transfer_complete' for x in limited.events),'real filesystem write failure cannot emit transfer complete')
    limited.finish()
    p=plan(data,server.route('badadler',[encrypted]),compressedLength=len(encrypted),depotKey=key.hex(),adler32=(zlib.adler32(data,0)^1)&0xffffffff)
    e=run(h,p,'failed'); check(counters(e)['downloadedVerifiedBytes']=='0','real SteamKit Adler32 mismatch rejected')
    p=plan(data,server.route('badsha',[encrypted]),compressedLength=len(encrypted),depotKey=key.hex(),adler32=zlib.adler32(data,0)&0xffffffff)
    p['chunks'][0]['sha1']='00'*20
    e=run(h,p,'failed'); check(counters(e)['downloadedVerifiedBytes']=='0','helper independently checks SHA1 after successful SteamKit length/Adler validation')
    p=plan(data,server.route('dirsymlink',[data])); outside_dir=root/'separate'; outside_dir.mkdir(); (root/p['jobID']).symlink_to(outside_dir)
    e=run(h,p,'failed');check(not list(outside_dir.iterdir()),'symlink job directory cannot escape fixture workspace')
    # Two adjacent chunks use per-file offsets, not one count per whole file.
    first,second=data[:len(data)//2],data[len(data)//2:]
    p=plan(first,server.route('part1',[first]));p['chunks'].append(dict(file='resource.bin',offset=len(first),length=len(second),sha1=hashlib.sha1(second).hexdigest(),url=server.route('part2',[second])))
    e=run(h,p);check(counters(e)['downloadedVerifiedBytes']==str(len(data)) and (root/p['jobID']/p['manifestID']/'resource.bin').read_bytes()==data,'multi-chunk verified writes respect exact offsets and total')
    outside=root/'outside'; outside.write_bytes(b'unchanged')
    for kind in ['symlink','hardlink','fifo']:
        p=plan(data,server.route(kind,[data])); d=root/p['jobID']/p['manifestID']; d.mkdir(parents=True); f=d/'resource.bin'
        if kind=='symlink': f.symlink_to(outside)
        elif kind=='hardlink': os.link(outside,f)
        else: os.mkfifo(f)
        e=run(h,p,'failed'); check(counters(e)['downloadedVerifiedBytes']=='0' and outside.read_bytes()==b'unchanged',kind+' destination safely denied without blocking')
    p=plan(data,server.route('cancel',[data],slow=True)); h.send('fixture_transfer',plan=p); h.wait('progress')
    another=plan(data,server.route('another',[data])); h.send('fixture_transfer',plan=another)
    check(h.wait('rejected')['detail']['reason']=='busy','one active transfer isolates job output')
    h.send('cancel',jobID=p['jobID'],epoch=99)
    check(h.wait('rejected')['detail']['reason']=='stale_job','stale cancel cannot affect current epoch')
    h.send('cancel',jobID=p['jobID'],epoch=p['epoch']); h.wait('cancelled')
    f=root/p['jobID']/p['manifestID']/'resource.bin'; before=f.read_bytes(); count=len([e for e in h.events if e.get('jobID')==p['jobID']]); time.sleep(.35)
    check(f.read_bytes()==before and count==len([e for e in h.events if e.get('jobID')==p['jobID']]),'cancel ACK follows stopped writes and no late progress')
    check(not any(e['kind']=='transfer_complete' and e.get('jobID')==p['jobID'] for e in h.events),'cancel never emits complete')
    run(h,another); check(True,'new job succeeds after cancellation')
    # Preserve one completed chunk through cancellation of the next, then revalidate on resume.
    head=data[:8192]
    p=plan(head,server.route('resumehead',[head])); p['chunks'].append(dict(file='resource.bin',offset=len(head),length=len(data),sha1=hashlib.sha1(data).hexdigest(),url=server.route('resumetail',[data],slow=True)))
    h.send('fixture_transfer',plan=p)
    while True:
        event=h.wait('progress')
        if int(event['detail']['downloadedVerifiedBytes'])==len(head): break
    h.send('cancel',jobID=p['jobID'],epoch=1); h.wait('cancelled')
    p['epoch']=2; e=run(h,p); c=counters(e)
    check(c['reusedVerifiedBytes']==str(len(head)) and c['downloadedVerifiedBytes']==str(len(data)),'resume after mid-stream cancel revalidates completed chunk and downloads remaining chunk only')
    check(server.hits['/resumehead']==1 and server.hits['/resumetail']==2,'resume does not fetch verified head or double-count cancelled tail')
    h.process.stdin.write(b'{bad}\n');h.process.stdin.flush();check(h.wait('rejected')['detail']['reason']=='invalid_json','bad JSON rejected without crashing session')
    for mutation in [dict(file='../escape'),dict(url='https://example.com/file'),dict(offset=1),dict(length=0)]:
        p=plan(data,server.route('unused',[data]));p['chunks'][0].update(mutation);h.send('fixture_transfer',plan=p)
        check(h.wait('rejected')['detail']['reason']=='invalid_plan','untrusted plan denied '+str(mutation))
    for field,value in [('chunks',None),('chunks',[None]),('chunks',[dict(file=None,offset=0,length=1,sha1='00'*20,url=url)]),('chunks',[dict(file='x',offset=0,length=1,sha1=None,url=url)])]:
        invalid=plan(data,url); invalid[field]=value; h.send('fixture_transfer',plan=invalid)
        check(h.wait('rejected')['detail']['reason']=='invalid_plan','nullable JSON fields reject without crash '+str(value))
    h.finish()
    prod=Helper();prod.send('fixture_transfer',plan=another);check(prod.wait('rejected')['detail']['reason']=='command_not_available','production mode refuses fixture/URL authorization');prod.finish()
    for payload,label in [(b'x'*65537+b'\n','line limit'),(b'\xff\n','UTF8'),(b'{','unterminated EOF')]:
        proc=subprocess.Popen([str(BINARY)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        output,error=proc.communicate(payload,timeout=5)
        check(proc.returncode==65 and b'input_line_limit_or_utf8' in output,label+' is bounded and terminates own child')
    # Fragmented one-byte pipe input and multiple commands in a single write use the same framing.
    proc=subprocess.Popen([str(BINARY)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    command=json.dumps(dict(v=1,commandName='unknown',requestID=str(uuid.uuid4()))).encode()+b'\r\n'
    for b in command:proc.stdin.write(bytes([b]));proc.stdin.flush()
    end=json.dumps(dict(v=1,commandName='shutdown',requestID=str(uuid.uuid4()))).encode()+b'\n'
    out,err=proc.communicate(end,timeout=5); events=[json.loads(line) for line in out.splitlines()]
    check(proc.returncode==0 and [e['kind'] for e in events]==['ready','rejected','stopped'],'fragmented JSONL and CRLF preserve message boundaries')
    check(all(child.poll() is not None for child in children),'all owned helper processes reaped with no residual children')
    server.shutdown()
result=dict(passed=len(checks),checks=checks,helper=str(BINARY),helperSHA256=hashlib.sha256(BINARY.read_bytes()).hexdigest(),
    scope='real ARM64 child, actual loopback HTTP/SteamKit2 processing only; no Steam auth or production Workshop transfer',
    cleanup='all helper processes awaited; private temporary tree removed; no global processes touched')
print(json.dumps(result,ensure_ascii=False,indent=2))
