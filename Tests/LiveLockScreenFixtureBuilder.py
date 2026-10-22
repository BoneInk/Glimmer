import pathlib,os,json,uuid,shutil,hashlib,stat,sys
repo=pathlib.Path(__file__).resolve().parent.parent
parent=pathlib.Path('/Users/Shared/GlimmerNativeLockScreen')
if not parent.exists(): parent.mkdir(mode=0o755)
assert not parent.is_symlink() and parent.stat().st_uid in (0,os.getuid()) and parent.stat().st_mode & 0o022 == 0
user=parent/str(os.getuid())
if not user.exists(): user.mkdir(mode=0o700)
assert not user.is_symlink() and user.stat().st_uid == os.getuid() and user.stat().st_mode & 0o077 == 0
base=user/('isolated-live-'+str(uuid.uuid4()));base.mkdir(mode=0o700)
profile=pathlib.Path(sys.argv[1]);receipt=json.loads((profile/'SceneBackend/active-receipt.json').read_text());digest=receipt['manifestIdentity']['sha256']
assert len(digest)==64 and all(c in '0123456789abcdef' for c in digest)
assets=profile/'Workshop/SteamContent/scene-runtime-assets'/digest/'content/assets'
for kind in (['web','web-network'] if len(sys.argv)>3 and sys.argv[3]=='--web-only' else ['scene','web','web-network']):
 folder=base/kind;folder.mkdir(mode=0o700);aid=str(uuid.uuid4()).upper();live=folder/('live-'+aid);live.mkdir(mode=0o700);project=live/'project'
 if kind=='scene':
  shutil.copytree(repo/'Tests/Fixtures/SceneScriptWallpaper',project)
  scene=json.loads((project/'scene.json').read_text());scene['objects'][1]['angles']={'value':'0 0 0','script':'export function update(value) { return new Vec3(0, 0, (engine.timeOfDay * 86400 % 60) * 6); }'};(project/'scene.json').write_text(json.dumps(scene))
  shutil.copytree(assets,live/'assets')
  for slot in range(8): (folder/'SceneCaches'/aid/('slot'+str(slot))).mkdir(parents=True,mode=0o700)
 else:
  project.mkdir(mode=0o700);(project/'project.json').write_text(json.dumps({'type':'web','file':'index.html','general':{'properties':{}}}))
  (project/'index.html').write_text('''<!doctype html><html><head><style>html,body{margin:0;width:100%;height:100%;background:#12334d;color:white;font:28px sans-serif}#clock{padding:30px}#weather{padding:30px;color:#69e2ac}</style></head><body><div id="clock"></div><div id="weather"></div><script>window.networkResult='pending'; fetch('https://api.open-meteo.com/v1/forecast?latitude=0&longitude=0&current=temperature_2m').then(r=>r.json()).then(x=>{window.networkResult='allowed';document.getElementById('weather').textContent='Weather '+x.current.temperature_2m;}).catch(()=>{window.networkResult='blocked';document.getElementById('weather').textContent='Network blocked';}); function tick(){document.getElementById('clock').textContent=String(Date.now());document.body.style.background='rgb('+Math.floor(Date.now()/100%100+30)+',40,80)';requestAnimationFrame(tick);}tick();</script></body></html>''')
  shutil.copyfile(sys.argv[2],project/'video.mp4')
  html=project/'index.html';html.write_text(html.read_text().replace('<body>','<body><video autoplay loop playsinline src="video.mp4" style="position:absolute;right:0;bottom:0;width:50%;height:50%"></video>'))
 files=[]
 for p in sorted(live.rglob('*')):
  if p.is_dir():p.chmod(0o700)
  else:
   p.chmod(0o600);d=p.read_bytes();files.append(dict(path=p.relative_to(live).as_posix(),size=len(d),sha256=hashlib.sha256(d).hexdigest()))
 recipe=dict(assetID=aid,kind='scene' if kind=='scene' else 'web',width=640,height=400,fps=12,propertiesJSON='e30=',sceneProperties={},projectDigest=hashlib.sha256((project/'project.json').read_bytes()).hexdigest(),assetsManifestDigest=digest if kind=='scene' else '0'*64,allowHTTPS=kind=='web-network',files=files)
 if kind!='scene':recipe['entryFile']='index.html'
 (live/'recipe.json').write_text(json.dumps(recipe));(live/'recipe.json').chmod(0o600)
 (folder/'config.json').write_text(json.dumps(dict(schemaVersion=2,assetID=aid,videoFileName='',liveDirectoryName=live.name,gravity='fill',isMuted=True)));(folder/'config.json').chmod(0o600)
print(base)
