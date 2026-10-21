#!/usr/bin/env python3
"""Exercise production command gates WITHOUT a valid login request or any Steam connection."""
import hashlib,json,os,pathlib,subprocess,sys,tempfile,uuid
binary=pathlib.Path(sys.argv[1]).resolve();passed=[]
def check(value,name):
 if not value:raise AssertionError(name)
 passed.append(name)
def request(command,**fields):return dict(v=1,commandName=command,requestID=str(uuid.uuid4()),**fields)
with tempfile.TemporaryDirectory(prefix='gw-content-cli-') as tmp:
 root=pathlib.Path(tmp).resolve();secret='ORIGINAL-FIXTURE-NOT-A-REAL-CREDENTIAL'
 invalid=[request('login'),request('login',auth=dict(method='invalid-offline-test',username='fixture',password=secret)),
 request('download',sessionID=str(uuid.uuid4()),jobID=str(uuid.uuid4()),epoch=1,publishedFileID='123'),
 request('engine_assets',sessionID=str(uuid.uuid4()),jobID=str(uuid.uuid4()),epoch=1,appID=431960,desiredResources=['materials/particle/halo.tex']),
 request('engine_assets',sessionID=str(uuid.uuid4()),jobID=str(uuid.uuid4()),epoch=1,appID=431960,desiredResources=['../../arbitrary']),
 request('auth_response',response=dict(sessionID=str(uuid.uuid4()),challengeID=str(uuid.uuid4()),code='ABCDE')),
 request('logout',sessionID=str(uuid.uuid4())),request('auth_cancel',sessionID=str(uuid.uuid4())),request('pause'),
 request('fixture_transfer',plan=dict(jobID=str(uuid.uuid4()),epoch=1,appID=431960,publishedFileID='123',manifestID='456',depotID=431960,chunks=[])),
 request('download',sessionID=str(uuid.uuid4()),jobID=str(uuid.uuid4()),epoch=1,publishedFileID='123',url='http://example.invalid/forbidden')]
 end=request('shutdown');data=b''.join(json.dumps(x).encode()+b'\n' for x in invalid+[end])
 process=subprocess.Popen([str(binary),'--workspace-root',str(root)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 out,err=process.communicate(data,timeout=8);events=[json.loads(line) for line in out.splitlines()]
 check(process.returncode==0,'production-mode native child exits cleanly with no valid login')
 check(events[0]['kind']=='ready' and events[0]['detail']['productionAuthentication'] is True and events[0]['detail']['productionWorkshopDownload'] is True and events[0]['detail']['productionEngineAssets'] is True,'production command capability is explicitly gated by private workspace flag')
 check(events[0]['detail']['liveAccountAcceptance']=='not_run','ready distinguishes implemented capability from real account acceptance')
 expected=['auth_request_missing','invalid_auth_request','session_not_authenticated','session_not_authenticated','invalid_engine_asset_request','stale_or_invalid_auth_response','stale_session','stale_session','command_not_available','command_not_available','invalid_json']
 actual=[e['detail']['reason'] for e in events if e['kind']=='rejected'];check(actual==expected,'strict production auth/download/fixture/URL command gates return exact semantic errors')
 check(not any(e['kind'] in ('auth_started','auth_challenge','auth_result','started','resolving','transfer_complete','engine_assets_resolving','engine_assets_started','engine_assets_complete') for e in events),'invalid requests do not connect, authenticate, transfer or fake success')
 check(secret.encode() not in out+err and b'fixture' not in err,'pipe rejection never echoes credential payload or raw exception')
 check(events[-1]['kind']=='stopped' and not list(root.iterdir()),'shutdown reaps own child and invalid requests create no download or token files')
 bad=root/'public';bad.mkdir(mode=0o755);bad.chmod(0o755)
 p=subprocess.run([str(binary),'--workspace-root',str(bad)],input=b'',capture_output=True,timeout=5)
 check(p.returncode==64 and b'workspace_not_private_canonical_directory' in p.stdout,'group/world-readable workspace rejected before any connection')
 link=root/'alias';link.symlink_to(root,target_is_directory=True)
 p=subprocess.run([str(binary),'--workspace-root',str(link)],input=b'',capture_output=True,timeout=5)
 check(p.returncode==64 and b'workspace_not_private_canonical_directory' in p.stdout,'symlink workspace rejected before any connection')
print(json.dumps(dict(passed=len(passed),checks=passed,helperManagedSHA256=hashlib.sha256(binary.with_suffix('.dll').read_bytes()).hexdigest(),scope='production JSONL command gates only; all login inputs intentionally invalid before adapter construction; no Steam network'),indent=2))
