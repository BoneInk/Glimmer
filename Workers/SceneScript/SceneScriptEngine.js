// Original restricted SceneScript host. Acorn parses modules before export lowering;
// no textual replacement occurs inside user strings, comments, regex or templates.
(function () {
  'use strict';
  const parse = acorn.parse, stringify = JSON.stringify, decode = JSON.parse;
  const NativeDate=Date, nativeApply=Reflect.apply;
  const localHours=Date.prototype.getHours, localMinutes=Date.prototype.getMinutes, localSeconds=Date.prototype.getSeconds, localMilliseconds=Date.prototype.getMilliseconds;
  const own = (o,k) => Object.prototype.hasOwnProperty.call(o,k);
  const targets = new Set(['origin','angles','scale','size','visible','color','alpha','text']);
  const unsupportedEvents = new Set(['destroy','applyGeneralSettings','cursorEnter','cursorLeave','cursorMove','cursorDown','cursorUp','cursorClick','mediaStatusChanged','mediaPlaybackChanged','mediaPropertiesChanged','mediaThumbnailChanged','mediaTimelineChanged']);
  const moduleFactory=GWSceneScriptModules,scopeAnalyzer=GWSceneScriptScope.analyze,builtinsFactory=GWSceneScriptBuiltins;
  let layers = [], scripts = [], direct = [], previous = {}, currentProperties = {}, environment = null, currentInput = {cursorWorldPosition:null}, clock = {runtime:0,frametime:0};
  const layerData=new WeakMap(),groupTargets=new Set(['origin','angles','scale','visible']);
  class Vec3 {
    constructor(x=0,y,z) {
      if (typeof x === 'string') { const a=x.trim().split(/\s+/).map(Number); [x,y,z]=a; }
      else if (x && typeof x==='object') { const a=x; x=a.x; y=a.y; z=a.z===undefined?0:a.z; }
      else if (y===undefined) { y=x; z=x; }
      this.x=Number(x); this.y=Number(y===undefined?0:y); this.z=Number(z===undefined?0:z);
    }
    copy(){return new this.constructor(this);} lengthSqr(){return this.dot(this);}
    length(){return Math.sqrt(this.lengthSqr());} normalize(){const n=this.length();return n?this.divide(n):this.copy();}
    isFinite(){return [this.x,this.y,this.z].every(Number.isFinite);}
    toString(){return `${this.x} ${this.y} ${this.z}`;}
    dot(v){return this.x*v.x+this.y*v.y+this.z*(v.z===undefined?0:v.z);}
    distanceSqr(v){return this.subtract(v).lengthSqr();} distance(v){return Math.sqrt(this.distanceSqr(v));}
    equals(v){return this.distanceSqr(v)<1e-10;} negate(){return this.multiply(-1);}
    _op(v,f){const a=typeof v==='number'?new Vec3(v):new Vec3(v);return new this.constructor(f(this.x,a.x),f(this.y,a.y),f(this.z,a.z));}
    add(v){return this._op(v,(a,b)=>a+b);} subtract(v){return this._op(v,(a,b)=>a-b);}
    multiply(v){return this._op(v,(a,b)=>a*b);} divide(v){return this._op(v,(a,b)=>a/b);}
    min(v){return this._op(v,Math.min);} max(v){return this._op(v,Math.max);}
    mix(v,t){return this.multiply(1-t).add(new this.constructor(v).multiply(t));}
    clamp(a,b){return this.max(a).min(b);} abs(){return this._op(0,a=>Math.abs(a));}
    round(){return this._op(0,a=>Math.round(a));} floor(){return this._op(0,a=>Math.floor(a));}
    ceil(){return this._op(0,a=>Math.ceil(a));} fract(){return this._op(0,a=>a-Math.floor(a));}
    cross(v){return new Vec3(this.y*v.z-this.z*v.y,this.z*v.x-this.x*v.z,this.x*v.y-this.y*v.x);}
  }
  class Vec2 extends Vec3 {
    constructor(x=0,y){super(x,y===undefined?(typeof x==='object'?x.y:x):y,0);delete this.z;}
    dot(v){return this.x*v.x+this.y*v.y;} isFinite(){return Number.isFinite(this.x)&&Number.isFinite(this.y);}
    toString(){return `${this.x} ${this.y}`;}
  }
  const hierarchy=GWSceneScriptHierarchy({getLayers:()=>layers,data:layer=>layerData.get(layer),Vec3});
  function valueFor(target,v) {
    if (target==='visible') { if(typeof v!=='boolean')throw Error('Visibility must be boolean'); return v; }
    if (target==='alpha') { if(typeof v!=='number'||!Number.isFinite(v)||v<0||v>1)throw Error('Opacity must be finite 0...1');return v; }
    if (target==='text') {
      if(typeof v!=='string')throw Error('Text must be a string');
      let bytes=0;for(const character of v){const point=character.codePointAt(0);bytes+=point<=0x7f?1:point<=0x7ff?2:point<=0xffff?3:4;if(bytes>4096||point<=0x1f||point>=0x7f&&point<=0x9f)throw Error('Text is invalid or exceeds 4096 UTF-8 bytes');}
      return v;
    }
    const vector=target==='size'?new Vec2(v):new Vec3(v);
    if(!vector.isFinite())throw Error('Nonfinite Scene vector');
    if(target==='color'&&[vector.x,vector.y,vector.z].some(x=>x<0||x>1))throw Error('Color outside 0...1');
    if(target==='size'&&(vector.x<=0||vector.y<=0||vector.x>16384||vector.y>16384))throw Error('Invalid Scene size');
    if(target==='origin'&&vector.z!==0||target==='angles'&&(vector.x!==0||vector.y!==0)||target==='scale'&&vector.z!==1)throw Error('Unsupported 3D Scene transform');
    return vector;
  }
  function wrapLayer(raw) {
    if(raw.isTransformOnly!==undefined&&typeof raw.isTransformOnly!=='boolean')throw Error('Invalid layer kind');
    const object={id:raw.id,name:raw.name,parentID:raw.parentID===undefined?null:raw.parentID,isTransformOnly:raw.isTransformOnly===true};
    for(const k of targets)if(k!=='text'||raw.text!==undefined&&raw.text!==null)object[k]=valueFor(k,raw[k]);
    if(object.isTransformOnly&&own(object,'text'))throw Error('Transform-only layers cannot expose text');
    let proxy;
    proxy=new Proxy(object,{
      get(o,k){
        if(k==='getParent')return ()=>hierarchy.getParent(proxy);
        if(k==='getChildren')return ()=>hierarchy.getChildren(proxy);
        if(k==='setParent')return (parent,adjust,attachment)=>hierarchy.setParent(proxy,parent,adjust,attachment);
        if(o.isTransformOnly&&targets.has(k)&&!groupTargets.has(k))throw Error(`Transform-only layers do not expose ${String(k)}`);
        if(typeof k==='symbol'||own(o,k))return o[k];throw Error(`Unsupported layer property: ${String(k)}`);
      },
      set(o,k,v){if(!targets.has(k)||!own(o,k)||o.isTransformOnly&&!groupTargets.has(k))throw Error(`Unsupported layer write: ${String(k)}`);o[k]=valueFor(k,v);return true;},
      ownKeys(o){return Reflect.ownKeys(o).filter(k=>!o.isTransformOnly||!targets.has(k)||groupTargets.has(k));},
      getOwnPropertyDescriptor(o,k){
        if(o.isTransformOnly&&targets.has(k)&&!groupTargets.has(k))return undefined;
        const descriptor=Reflect.getOwnPropertyDescriptor(o,k);
        if(descriptor&&!targets.has(k))descriptor.writable=false;
        return descriptor;
      },
      preventExtensions(){throw Error('Scene layer extensibility cannot be changed');},
      defineProperty(){throw Error('Scene layer properties cannot be redefined');},
      deleteProperty(){throw Error('Scene layer properties cannot be deleted');},
      setPrototypeOf(){throw Error('Scene layer prototypes cannot be replaced');}
    });
    layerData.set(proxy,object);return proxy;
  }
  function cloneValue(v) {
    if(v instanceof Vec2)return new Vec2(v);if(v instanceof Vec3)return new Vec3(v);
    if(Array.isArray(v))return v.map(cloneValue);
    if(v&&typeof v==='object'){const o={};for(const k of Object.keys(v))Object.defineProperty(o,k,{value:cloneValue(v[k]),writable:true,enumerable:true,configurable:true});return o;}
    return v;
  }
  function validateEnvironment(value) {
    if(!value||!value.canvasSize||!['wallpaper'].includes(value.presentation))throw Error('Invalid SceneScript host environment');
    const canvas=new Vec2(value.canvasSize);
    if(!canvas.isFinite()||canvas.x<=0||canvas.y<=0||canvas.x>1e6||canvas.y>1e6)throw Error('Invalid project canvas');
    let screen=null;
    if(value.screenResolution!==undefined&&value.screenResolution!==null){screen=new Vec2(value.screenResolution);if(!screen.isFinite()||![screen.x,screen.y].every(x=>Number.isInteger(x)&&x>=1&&x<=131072))throw Error('Invalid screen resolution');}
    return {canvasSize:canvas,screenResolution:screen,presentation:value.presentation};
  }
  function screenSize(){if(!environment||!environment.screenResolution)throw Error('Actual screen resolution is unavailable for this host');return environment.screenResolution;}
  function validateInput(value) {
    if(value===undefined||value===null)return {cursorWorldPosition:null};
    if(typeof value!=='object'||Array.isArray(value)||Object.keys(value).some(k=>k!=='cursorWorldPosition'))throw Error('Invalid SceneScript input snapshot');
    if(value.cursorWorldPosition===undefined||value.cursorWorldPosition===null)return {cursorWorldPosition:null};
    const cursor=new Vec3(value.cursorWorldPosition);
    if(!cursor.isFinite()||[cursor.x,cursor.y,cursor.z].some(x=>Math.abs(x)>1e12))throw Error('Invalid cursor world position');
    return {cursorWorldPosition:cursor};
  }
  const input=new Proxy({}, {
    get(_,k){if(k==='cursorWorldPosition')return currentInput.cursorWorldPosition&&currentInput.cursorWorldPosition.copy();throw Error(`Unsupported input API: ${String(k)}`);},
    set(){throw Error('Input properties are read-only');},defineProperty(){throw Error('Input properties cannot be redefined');},
    deleteProperty(){throw Error('Input properties cannot be deleted');},setPrototypeOf(){throw Error('Input prototype is read-only');}
  });
  const engine=new Proxy({}, {
    get(_,k){
      if(k==='runtime'||k==='frametime')return clock[k];
      if(k==='timeOfDay'){
        const date=new NativeDate(), seconds=nativeApply(localHours,date,[])*3600+nativeApply(localMinutes,date,[])*60+nativeApply(localSeconds,date,[])+nativeApply(localMilliseconds,date,[])/1000;
        const value=seconds/86400;if(!Number.isFinite(value)||value<0||value>=1)throw Error('Local time-of-day is unavailable');return value;
      }
      if(k==='canvasSize'){if(!environment)throw Error('Project canvas is unavailable');return environment.canvasSize.copy();}
      if(k==='screenResolution')return screenSize().copy();
      if(k==='userProperties')return cloneValue(currentProperties);
      if(k==='isLandscape')return ()=>screenSize().x>=screenSize().y;
      if(k==='isPortrait')return ()=>screenSize().x<screenSize().y;
      if(k==='isDesktopDevice')return ()=>true;
      if(k==='isMobileDevice'||k==='isRunningInEditor'||k==='isScreensaver')return ()=>false;
      if(k==='isWallpaper')return ()=>{if(!environment)throw Error('Host presentation is unavailable');return environment.presentation==='wallpaper';};
      throw Error(`Unsupported engine API: ${String(k)}`);
    },
    set(){throw Error('Engine properties are read-only');},defineProperty(){throw Error('Engine properties cannot be redefined');},
    deleteProperty(){throw Error('Engine properties cannot be deleted');},setPrototypeOf(){throw Error('Engine prototype is read-only');}
  });
  const scene=new Proxy({}, {get(_,k){if(k==='getLayer')return id=>hierarchy.find(id);if(k==='getLayerCount')return ()=>layers.length;if(k==='enumerateLayers')return ()=>layers.slice();throw Error(`Unsupported scene API: ${String(k)}`);}});
  function propertiesBuilder(values) {
    const builder={};for(const name of ['addSlider','addCheckbox','addColor','addCombo','addText'])builder[name]=description=>{if(!description||typeof description.name!=='string')throw Error('Script property requires name');if(!own(values,description.name))values[description.name]=description.value;return builder;};
    builder.finish=()=>values;
    return new Proxy(builder,{get(o,k){if(own(o,k))return o[k];throw Error(`Unsupported script property builder: ${String(k)}`);}});
  }
  function rawProperties(payload) {
    const result={};for(const k of Object.keys(payload||{})){
      const x=payload[k],v=x&&typeof x==='object'&&own(x,'value')?x.value:x;
      Object.defineProperty(result,k,{value:x&&x.type==='color'?new Vec3(v):cloneValue(v),writable:true,enumerable:true,configurable:true});
    }return result;
  }
  function setDirect(values) {
    for(const b of direct)if(own(values,b.propertyKey)){const layer=layers.find(l=>l.id===b.layerID);if(!layer)throw Error('Missing direct binding layer');layer[b.target]=valueFor(b.target,values[b.propertyKey]);}
    for(const s of scripts)for(const name of Object.keys(s.mapping))if(own(values,s.mapping[name]))s.properties[name]=cloneValue(values[s.mapping[name]]);
  }
  function notify(values,initial) {
    const changed={};for(const k of Object.keys(values))if(initial||stringify(values[k])!==stringify(previous[k]))changed[k]=values[k];
    if(initial||Object.keys(changed).length)for(const s of scripts)if(typeof s.exports.applyUserProperties==='function')s.exports.applyUserProperties(cloneValue(changed));
    previous=decode(stringify(values));
  }
  function snapshot() {
    hierarchy.validate();
    const result=layers.map(l=>{const raw=layerData.get(l),o={id:raw.id,name:raw.name,parentID:raw.parentID,isTransformOnly:raw.isTransformOnly};for(const k of targets)if(own(raw,k))o[k]=valueFor(k,raw[k]);return o;});
    return {layers:result,hasUpdateHandlers:scripts.some(s=>typeof s.exports.update==='function'),canApplyUserProperties:scripts.some(s=>typeof s.exports.applyUserProperties==='function')};
  }
  function invoke(s,event) {
    const f=s.exports[event];if(typeof f!=='function')return;
    const old=s.layer[s.target];const input=old&&typeof old==='object'?old.copy():old;
    const returned=f(input);if(returned&&typeof returned.then==='function')throw Error('Async SceneScript events unsupported');
    if(returned!==undefined)s.layer[s.target]=valueFor(s.target,returned);
  }
  return function(request) {
    try {
      if(request.operation==='configure'){
        const p=request.program;
        if(!p||!Array.isArray(p.layers)||p.layers.length>512||!Array.isArray(p.bindings)||p.bindings.length>64)throw Error('Invalid SceneScript program');
        layers=p.layers.map(wrapLayer);hierarchy.validate();scripts=[];direct=p.directBindings||[];previous={};currentProperties=rawProperties(request.properties);environment=request.environment?validateEnvironment(request.environment):null;currentInput={cursorWorldPosition:null};clock={runtime:0,frametime:0};
        for(const b of p.bindings){
          const layer=layers.find(x=>x.id===b.layerID);if(!layer||!targets.has(b.target)||!own(layerData.get(layer),b.target)||layerData.get(layer).isTransformOnly&&!groupTargets.has(b.target))throw Error('Invalid script attachment');
          const properties=decode(stringify(b.scriptProperties||{})),mapping=b.scriptPropertyBindings||{};
          const exported=moduleFactory({parse,analyze:scopeAnalyzer,builtins:builtinsFactory(Vec2,Vec3),sources:p.modules||{},source:b.source,
            globals:{engine,input,thisLayer:layer,thisObject:layer,thisScene:scene,Vec2,Vec3,createScriptProperties:()=>propertiesBuilder(properties),console:Object.freeze({log(){},warn(){},error(){}})}});
          for(const key of Object.keys(exported))if(unsupportedEvents.has(key))throw Error(`Unsupported SceneScript event: ${key}`);
          for(const key of ['init','update','applyUserProperties','resizeScreen'])if(exported[key]!==undefined&&typeof exported[key]!=='function')throw Error(`SceneScript ${key} must be a function`);
          if(exported.scriptProperties&&exported.scriptProperties!==properties){for(const key of Object.keys(properties))exported.scriptProperties[key]=properties[key];}
          scripts.push({layer,target:b.target,exports:exported,properties:exported.scriptProperties||properties,mapping});
        }
        const props=currentProperties;setDirect(props);
        for(const s of scripts)invoke(s,'init');notify(props,true);
      }else if(request.operation==='step'){
        clock={runtime:request.runtime,frametime:request.frameTime};
        if(!Number.isFinite(clock.runtime)||!Number.isFinite(clock.frametime)||clock.runtime<0||clock.frametime<0)throw Error('Invalid frame timing');
        currentInput=validateInput(request.input);
        for(const s of scripts)invoke(s,'update');
      }else if(request.operation==='properties'){
        clock={runtime:request.runtime,frametime:0};const props=rawProperties(request.properties);for(const k of Object.keys(props))Object.defineProperty(currentProperties,k,{value:cloneValue(props[k]),writable:true,enumerable:true,configurable:true});setDirect(props);notify(currentProperties,false);
      }else if(request.operation==='resize'){
        const next=validateEnvironment(request.environment);
        if(!next.screenResolution)throw Error('Actual screen resolution is unavailable for resize');
        if(!environment||next.canvasSize.x!==environment.canvasSize.x||next.canvasSize.y!==environment.canvasSize.y||next.presentation!==environment.presentation)throw Error('Resize cannot replace canvas or presentation');
        const old=environment.screenResolution, changed=!old||old.x!==next.screenResolution.x||old.y!==next.screenResolution.y;
        if(!Number.isFinite(request.runtime)||request.runtime<0)throw Error('Invalid resize timing');
        environment=next;clock={runtime:request.runtime,frametime:0};
        if(changed)for(const s of scripts)if(typeof s.exports.resizeScreen==='function'){
          const result=s.exports.resizeScreen(next.screenResolution.copy());
          if(result&&typeof result.then==='function')throw Error('Async SceneScript events unsupported');
        }
      }else throw Error('Unknown worker request');
      return stringify({id:request.id,ok:true,frame:snapshot()});
    }catch(error){return stringify({id:request.id,ok:false,error:String(error&&error.message||error).slice(0,2048)});}
  };
})()
