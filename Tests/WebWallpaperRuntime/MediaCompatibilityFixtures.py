"""Generate a bounded codec matrix in a private, isolated staging directory."""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import uuid

ffmpeg, evidence = sys.argv[1:]
evidence = pathlib.Path(evidence).resolve()
evidence.mkdir(parents=True, exist_ok=True)
parent = pathlib.Path('/Users/Shared/GlimmerNativeLockScreen')
assert not parent.is_symlink() and parent.stat().st_uid in (0, os.getuid()) and parent.stat().st_mode & 0o022 == 0
user = parent / str(os.getuid())
assert not user.is_symlink() and user.stat().st_uid == os.getuid() and user.stat().st_mode & 0o077 == 0
base = user / ('isolated-media-matrix-' + str(uuid.uuid4()))
base.mkdir(mode=0o700)
(evidence / 'fixtures.txt').write_text(str(base))

cases = []


def case(name, codec, pixel='yuv420p', profile=None, audio=None, alpha=False, extra=None, extension='webm', videos=1):
    cases.append(dict(name=name, codec=codec, pixel=pixel, profile=profile, audio=audio or [], alpha=alpha,
                      extra=extra or [], extension=extension, videos=videos, expectVideo=True))


case('mp4-h264', 'libx264', extension='mp4')
case('mp4-hevc', 'libx265', extension='mp4', extra=['-tag:v', 'hvc1', '-x265-params', 'pools=1:frame-threads=1'])
case('vp8', 'libvpx')
case('vp8-vorbis', 'libvpx', audio=['libvorbis'])
case('vp9-profile0', 'libvpx-vp9', profile=0)
case('vp9-opus', 'libvpx-vp9', profile=0, audio=['libopus'])
case('vp9-vorbis', 'libvpx-vp9', profile=0, audio=['libvorbis'])
case('vp9-profile1-444', 'libvpx-vp9', 'yuv444p', profile=1)
case('vp9-profile2-10bit', 'libvpx-vp9', 'yuv420p10le', profile=2)
case('vp9-profile2-12bit', 'libvpx-vp9', 'yuv420p12le', profile=2)
case('vp9-profile3-10bit', 'libvpx-vp9', 'yuv444p10le', profile=3)
case('vp9-profile3-12bit', 'libvpx-vp9', 'yuv444p12le', profile=3)
case('vp9-hdr10', 'libvpx-vp9', 'yuv420p10le', profile=2,
     extra=['-color_primaries', 'bt2020', '-color_trc', 'smpte2084', '-colorspace', 'bt2020nc'])
case('vp8-alpha', 'libvpx', 'yuva420p', alpha=True, extra=['-auto-alt-ref', '0'])
case('vp9-alpha', 'libvpx-vp9', 'yuva420p', profile=0, alpha=True, extra=['-auto-alt-ref', '0'])
case('vp9-two-audio', 'libvpx-vp9', profile=0, audio=['libopus', 'libopus'])
case('vp9-two-video', 'libvpx-vp9', profile=0, videos=2)
case('av1-8bit', 'libaom-av1')
case('av1-10bit', 'libaom-av1', 'yuv420p10le')
case('vp9-vfr', 'libvpx-vp9', profile=0, extra=['-vf', "select='not(eq(mod(n,5),3))'", '-fps_mode', 'vfr'])
case('vp9-start-offset', 'libvpx-vp9', profile=0, extra=['-vf', 'setpts=PTS+0.2/TB'])
case('vp9-live-cluster', 'libvpx-vp9', profile=0, extra=['-live', '1'])
cases.extend([dict(name='html-css-clock', expectVideo=False), dict(name='html-webgl-clock', expectVideo=False)])
library = json.loads((pathlib.Path.home() / 'Library/Application Support/Glimmer/library.json').read_text())
for item in library['items']:
    path = pathlib.Path(item['filePath'])
    if '/WebProjects/' in str(path) and path.name == 'project.json' and item.get('workshopID') != '3823383023':
        cases.append(dict(name='actual-web-' + item['id'], expectVideo=False, sourceProject=str(path), title=item['title']))


def html(item):
    media = '<video id="video" autoplay muted loop playsinline src="media.' + item.get('extension', 'webm') + '"></video>' if item['expectVideo'] else ''
    return '''<!doctype html><style>html,body{margin:0;background:#125345;color:white}video{width:100%;height:100%}#clock{position:absolute;top:0}#spin{position:absolute;top:40px;background:orange;width:30px;height:30px;animation:s 1s linear infinite}@keyframes s{to{transform:rotate(360deg)}}#graphics{position:absolute;right:0;bottom:0;width:160px;height:96px}</style>''' + media + '''<div id="clock"></div><div id="spin"></div><canvas id="graphics" width="160" height="96"></canvas><script>
const state={loops:0,presented:0,frames:0,errors:[]};
const video=document.querySelector('video');
if(video){
  video.addEventListener('seeked',()=>{if(video.currentTime<.2)state.loops++});
  video.addEventListener('error',()=>state.errors.push(video.error?.code));
  if(video.requestVideoFrameCallback){const tick=()=>{state.presented++;video.requestVideoFrameCallback(tick)};video.requestVideoFrameCallback(tick);}
}
const mode=''' + json.dumps(item['name']) + ''';
const graphics=document.getElementById('graphics');
let gl=null,ctx=null,uniform=null;
if(mode==='html-webgl-clock'){
  gl=graphics.getContext('webgl',{preserveDrawingBuffer:true});
  if(gl){
    function shader(type,text){const s=gl.createShader(type);gl.shaderSource(s,text);gl.compileShader(s);if(!gl.getShaderParameter(s,gl.COMPILE_STATUS))throw Error(gl.getShaderInfoLog(s));return s;}
    const p=gl.createProgram();gl.attachShader(p,shader(gl.VERTEX_SHADER,'attribute vec2 p;void main(){gl_Position=vec4(p,0.,1.);}'));
    gl.attachShader(p,shader(gl.FRAGMENT_SHADER,'precision mediump float;uniform float t;void main(){gl_FragColor=vec4(t,.5,1.-t,1.);}'));gl.linkProgram(p);gl.useProgram(p);
    const b=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,b);gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([-1,-1,3,-1,-1,3]),gl.STATIC_DRAW);
    const a=gl.getAttribLocation(p,'p');gl.enableVertexAttribArray(a);gl.vertexAttribPointer(a,2,gl.FLOAT,false,0,0);uniform=gl.getUniformLocation(p,'t');
  }
}else{ctx=graphics.getContext('2d');}
function frame(t){state.frames++;document.getElementById('clock').textContent=String(Date.now());if(gl){gl.uniform1f(uniform,(Math.sin(t/300)+1)/2);gl.drawArrays(gl.TRIANGLES,0,3)}else{ctx.fillStyle='rgb('+Math.floor(t/10%255)+',80,180)';ctx.fillRect(0,0,160,96);}requestAnimationFrame(frame);}
requestAnimationFrame(frame);
window.__gwMediaMatrix={sample(){
  let alpha=null,pixel=null;
  try{if(video&&video.readyState>=2){const c=document.createElement('canvas');c.width=160;c.height=96;const x=c.getContext('2d');x.drawImage(video,0,0,160,96);alpha=[10,80,150].map(px=>x.getImageData(px,48,1,1).data[3]);}}
  catch(e){state.errors.push(String(e));}
  if(gl){const p=new Uint8Array(4);gl.readPixels(80,48,1,1,gl.RGBA,gl.UNSIGNED_BYTE,p);pixel=Array.from(p);}
  return {...state,alpha,pixel,webgl:!!gl,transform:getComputedStyle(document.getElementById('spin')).transform};
}};
</script>'''


def build(item):
    folder = base / item['name']
    folder.mkdir(mode=0o700)
    aid = str(uuid.uuid4()).upper()
    live = folder / ('live-' + aid)
    project = live / 'project'
    project.mkdir(parents=True, mode=0o700)
    result = dict(item, directory=str(folder))
    if item.get('sourceProject'):
        source = pathlib.Path(item['sourceProject'])
        paths = list(source.parent.rglob('*'))
        assert not any(p.is_symlink() or not (p.is_dir() or stat.S_ISREG(p.stat().st_mode)) for p in paths)
        assert sum(p.stat().st_size for p in paths if p.is_file()) <= 128*1024*1024
        shutil.copytree(source.parent, project, dirs_exist_ok=True)
        document = json.loads((project / 'project.json').read_text())
        assert document['type'].lower() == 'web'
        result['generated'] = True
        entry = document['file']
        properties = document.get('general', {}).get('properties', {})
    else:
        entry = 'index.html'
        properties = {}
    if item['expectVideo']:
        output = project / ('media.' + item['extension'])
        source = 'testsrc2=s=160x96:r=12:d=1.5'
        if item['alpha']:
            source = "nullsrc=s=160x96:r=12:d=1.5,format=yuva420p,geq=lum='64+mod(N*20,128)':cb=90:cr=240:a='if(lt(X,W/3),0,if(lt(X,2*W/3),128,255))'"
        args = [ffmpeg, '-hide_banner', '-nostdin', '-y', '-filter_threads', '1', '-f', 'lavfi', '-i', source]
        if item['videos'] == 2:
            args += ['-f', 'lavfi', '-i', 'testsrc2=s=160x96:r=12:d=1.5']
        for index, audio in enumerate(item['audio']):
            args += ['-f', 'lavfi', '-i', f'sine=frequency={440+index*220}:sample_rate=48000:duration=1.5']
        for i in range(item['videos']):
            args += ['-map', f'{i}:v:0']
        for i, audio in enumerate(item['audio']):
            args += ['-map', f'{item["videos"]+i}:a:0', f'-c:a:{i}', audio]
        args += ['-c:v', item['codec'], '-threads', '1', '-pix_fmt', item['pixel'], '-g', '12']
        if item['profile'] is not None:
            args += ['-profile:v', str(item['profile'])]
        if item['codec'].startswith('libvpx'):
            args += ['-deadline', 'realtime', '-cpu-used', '8', '-b:v', '0', '-crf', '32']
        if item['codec'] == 'libaom-av1':
            args += ['-cpu-used', '8', '-row-mt', '0', '-b:v', '0', '-crf', '32']
        args += item['extra'] + [str(output)]
        process = subprocess.run(args, capture_output=True, text=True)
        (evidence / (item['name'] + '-encode.log')).write_text(process.stderr)
        if process.returncode:
            return dict(result, generated=False, error=process.stderr[-1800:])
        result.update(generated=True, sourceBytes=output.stat().st_size,
                      sourceSHA256=hashlib.sha256(output.read_bytes()).hexdigest(), sourcePrefix=output.read_bytes()[:16].hex())
        if item['alpha']:
            decoder = 'libvpx-vp9' if item['codec'] == 'libvpx-vp9' else 'libvpx'
            reference = subprocess.run([ffmpeg, '-hide_banner', '-nostdin', '-c:v', decoder, '-i', str(output),
                                        '-frames:v', '1', '-pix_fmt', 'rgba', '-f', 'rawvideo', '-'], capture_output=True)
            raw = reference.stdout
            result['referenceAlpha'] = [raw[(48*160+x)*4+3] for x in [10,80,150]] if len(raw) == 160*96*4 else None
    else:
        result['generated'] = True
    if not item.get('sourceProject'):
        (project / 'index.html').write_text(html(item))
        (project / 'project.json').write_text(json.dumps(dict(type='web', file='index.html', general=dict(properties={}))))
    files = []
    for path in sorted(live.rglob('*')):
        if path.is_dir():
            path.chmod(0o700)
        else:
            path.chmod(0o600)
            data = path.read_bytes()
            files.append(dict(path=path.relative_to(live).as_posix(), size=len(data), sha256=hashlib.sha256(data).hexdigest()))
    live.chmod(0o700)
    import base64
    recipe = dict(assetID=aid, kind='web', width=640, height=400, fps=12,
                  propertiesJSON=base64.b64encode(json.dumps(properties).encode()).decode(), sceneProperties={},
                  projectDigest=hashlib.sha256((project / 'project.json').read_bytes()).hexdigest(),
                  assetsManifestDigest='0'*64, allowHTTPS=False, entryFile=entry, files=files)
    (live / 'recipe.json').write_text(json.dumps(recipe))
    (live / 'recipe.json').chmod(0o600)
    (folder / 'config.json').write_text(json.dumps(dict(schemaVersion=2,assetID=aid,videoFileName='',liveDirectoryName=live.name,gravity='fill',isMuted=True)))
    (folder / 'config.json').chmod(0o600)
    return result


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
    results = list(executor.map(build, cases))
(evidence / 'fixtures.json').write_text(json.dumps(results, indent=2))
print(json.dumps(dict(directory=str(base),generated=sum(x['generated'] for x in results),cases=len(results))))
