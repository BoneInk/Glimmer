window.calls=[];window.generalCalls=[];window.pauseCalls=[];window.fixtureTicks=0;window.fixturePaused=false;
setInterval(()=>{if(!window.fixturePaused)window.fixtureTicks++},20);
setTimeout(()=>{
 window.wallpaperPropertyListener={};
 setTimeout(()=>{
  window.wallpaperPropertyListener.applyUserProperties=async properties=>{
   window.calls.push(JSON.parse(JSON.stringify(properties)));
   if(properties.text && properties.text.value==='THROW')throw new Error('AUTHORED_TEST_FAILURE');
   if(properties.text && properties.text.value==='SLOW_THROW'){await new Promise(r=>setTimeout(r,200));throw new Error('SUPERSEDED_FAILURE')}
   if(properties.text && properties.text.value==='SLOW')await new Promise(r=>setTimeout(r,200));
   if(properties.enabled)document.getElementById('toggle').hidden=!properties.enabled.value;
   if(properties.color){let rgb=properties.color.value.split(' ').map(x=>Math.round(Number(x)*255));document.body.style.backgroundColor=`rgb(${rgb.join(',')})`}
   if(properties.slider)document.getElementById('subject').style.transform=`translateX(${properties.slider.value}px)`;
   if(properties.combo)document.body.dataset.combo=String(properties.combo.value);
   if(properties.text)document.getElementById('subject').textContent=properties.text.value;
  };
  window.wallpaperPropertyListener.applyGeneralProperties=properties=>window.generalCalls.push(JSON.parse(JSON.stringify(properties)));
  window.wallpaperPropertyListener.setPaused=paused=>{window.pauseCalls.push(paused);window.fixturePaused=paused};
 },120);
},120);

// This authored interval is created during document loading, outside native JS evaluation.
setInterval(()=>{
 if(!window.requestMediaTest)return;
 window.requestMediaTest=false;
 window.audioResult='pending';window.tone=new Audio('tone.wav');
 tone.play().then(()=>window.audioResult='played').catch(e=>window.audioResult=e.name);
 window.videoResult='pending';window.silentVideo=document.createElement('video');
 silentVideo.muted=true;silentVideo.loop=true;
 silentVideo.style.cssText='position:absolute;bottom:0;left:0;width:16px;height:16px';
 silentVideo.src='silent.mp4';document.body.appendChild(silentVideo);
 silentVideo.play().then(()=>window.videoResult='played').catch(e=>window.videoResult=e.name);
},100);
