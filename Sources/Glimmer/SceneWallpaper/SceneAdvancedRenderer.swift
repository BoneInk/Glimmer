import Foundation
import CoreGraphics
import ImageIO
import Metal
import simd

/// Original fixed-step particle backend. The authored operators all execute;
/// local curl noise and PRNG deliberately do not claim Windows numeric parity.
private final class SceneParticleSimulation {
    struct Particle {
        let index:Int64;let birth:Double;let life:Double;let size:Double;let color:SceneVector3;let alpha:Double;let angle:Double;let frequency:Double;let phase:Double;let noiseSpeed:Double
        var position:SIMD2<Double>;var velocity:SIMD2<Double>
    }
    let spec:SceneSpriteParticleSystem
    let seed:Int
    private var time:Double=0
    private var lastSpawn:Int64 = -1
    private var particles:[Particle]=[]
    init(_ spec:SceneSpriteParticleSystem,seed:Int) {self.spec=spec;self.seed=seed}
    private func spawn(_ index:Int64)->Particle {
        var state=UInt64(truncatingIfNeeded:seed) &* 0x9e3779b97f4a7c15 ^ UInt64(truncatingIfNeeded:index)
        func random()->Double {state &+= 0x9e3779b97f4a7c15;var x=state;x=(x^(x>>30)) &* 0xbf58476d1ce4e5b9;x=(x^(x>>27)) &* 0x94d049bb133111eb;x ^= x>>31;return Double(x>>11)/9_007_199_254_740_992}
        func pick(_ a:Double,_ b:Double)->Double {a+(b-a)*random()}
        let life=pick(spec.lifetimeMin,spec.lifetimeMax)
        var p=SIMD2<Double>(0,0)
        if spec.emitter == .sphererandom {let angle=random()*2 * .pi,radius=sqrt(pick(spec.radiusMin*spec.radiusMin,spec.radiusMax*spec.radiusMax));p = .init(cos(angle)*radius*spec.directions.x,sin(angle)*radius*spec.directions.y)}
        else {p = .init(pick(spec.boxMin.x,spec.boxMax.x)*spec.directions.x,pick(spec.boxMin.y,spec.boxMax.y)*spec.directions.y)}
        var velocity=SIMD2(pick(spec.velocityMin.x,spec.velocityMax.x),pick(spec.velocityMin.y,spec.velocityMax.y))
        let phase=pick(spec.turbulencePhaseMin,spec.turbulencePhaseMax)
        if spec.turbulentSpeedMax>0 {
            let speed=pick(spec.turbulentSpeedMin,spec.turbulentSpeedMax),angle=pick(spec.initialPhaseMin,spec.initialPhaseMax)+(p.x+p.y)*spec.turbulentScale+Double(index)/max(spec.rate,0.001)*spec.turbulentTimeScale+spec.turbulentOffset
            velocity += SIMD2(cos(angle),sin(angle))*speed
        }
        return .init(index:index,birth:Double(index)/max(spec.rate,0.001),life:life,size:pick(spec.sizeMin,spec.sizeMax),color:.init(x:pick(spec.colorMin.x,spec.colorMax.x),y:pick(spec.colorMin.y,spec.colorMax.y),z:pick(spec.colorMin.z,spec.colorMax.z)),alpha:pick(spec.alphaMin,spec.alphaMax),angle:pick(spec.rotationMin,spec.rotationMax),frequency:pick(spec.oscillateFrequencyMin,spec.oscillateFrequencyMax),phase:phase,noiseSpeed:pick(spec.turbulenceSpeedMin,spec.turbulenceSpeedMax),position:p,velocity:velocity)
    }
    func evaluate(runtime:Double,cursor:SIMD2<Double>?)throws->[SceneAdvancedSprite] {
        try spec.validate()
        guard runtime.isFinite,runtime>=0,runtime<=1e9 else {throw SceneWallpaperFailure(message:"Invalid advanced particle runtime.")}
        guard spec.rate>0,spec.maximumCount>0 else {return []}
        let target=runtime+spec.preRoll
        if target<time || target-time>60 {time=max(0,target-spec.lifetimeMax);lastSpawn=Int64(floor(time*spec.rate))-1;particles=[]}
        var steps=0
        repeat {
            try Task.checkCancellation()
            let next=min(target,time+1.0/60.0)
            let newest=Int64(floor(next*spec.rate))
            if newest>lastSpawn {
                guard newest-lastSpawn<=60_001 else {throw SceneWallpaperFailure(message:"Particle spawn work limit exceeded.")}
                for index in (lastSpawn+1)...newest {particles.append(spawn(index))}
                lastSpawn=newest
            }
            for i in particles.indices {
                let start=max(time,particles[i].birth),dt=max(0,next-start)
                if dt==0 {continue}
                var force=SIMD2(spec.gravity.x,spec.gravity.y)
                if particles[i].noiseSpeed>0 {
                    // Divergence-free periodic stream field, evaluated at 60 Hz.
                    // This is the declared local approximation for engine curl noise.
                    let x=particles[i].position.x*spec.turbulentScale*0.01+next*spec.turbulenceTimeScale+particles[i].phase
                    let y=particles[i].position.y*spec.turbulentScale*0.01-next*spec.turbulenceTimeScale
                    force += SIMD2(sin(x)*cos(y)*spec.turbulenceMask.x,-cos(x)*sin(y)*spec.turbulenceMask.y)*particles[i].noiseSpeed
                }
                if spec.controlPointAttract != 0,let cursor {
                    let delta=cursor-particles[i].position,distance=simd_length(delta)
                    if distance>1e-6 && distance<spec.controlPointThreshold {force += delta/distance*spec.controlPointAttract*(1-distance/spec.controlPointThreshold)}
                }
                if spec.drag<1e-8 {particles[i].position += particles[i].velocity*dt+force*(dt*dt/2);particles[i].velocity += force*dt}
                else {let decay=exp(-spec.drag*dt),integral = -expm1(-spec.drag*dt)/spec.drag;particles[i].position += particles[i].velocity*integral+force*((dt-integral)/spec.drag);particles[i].velocity=particles[i].velocity*decay+force*integral}
            }
            particles.removeAll{next-$0.birth >= $0.life}
            if particles.count>spec.maximumCount {particles.removeFirst(particles.count-spec.maximumCount)}
            time=next;steps+=1
            guard steps<=3601 else {throw SceneWallpaperFailure(message:"Particle fixed-step catch-up exceeds 60 seconds.")}
        } while time<target
        return particles.map { p in
            let age=max(0,target-p.birth),progress=min(1,age/p.life)
            func curve(_ a:Double,_ b:Double,_ start:Double)->Double {a+(b-a)*(start>=1 ? 0 : min(1,max(0,(progress-start)/(1-start))))}
            var alpha=p.alpha
            if spec.fadeIn>0 {alpha *= min(1,progress/spec.fadeIn)}
            if spec.fadeOut<1 {alpha *= min(1,max(0,(1-progress)/(1-spec.fadeOut)))}
            if spec.oscillateFrequencyMax>0 {let wave=0.5+0.5*sin(progress*p.frequency*2 * .pi+p.phase);alpha *= spec.oscillateAlphaMin+(spec.oscillateAlphaMax-spec.oscillateAlphaMin)*wave}
            return .init(position:p.position,velocity:p.velocity,size:p.size*curve(spec.sizeStart,spec.sizeEnd,spec.sizeChangeStart),color:.init(x:p.color.x*curve(spec.colorStart.x,spec.colorEnd.x,spec.colorChangeStart),y:p.color.y*curve(spec.colorStart.y,spec.colorEnd.y,spec.colorChangeStart),z:p.color.z*curve(spec.colorStart.z,spec.colorEnd.z,spec.colorChangeStart)),alpha:alpha,angle:p.angle,progress:progress)
        }
    }
}
private struct SceneAdvancedSprite {let position:SIMD2<Double>;let velocity:SIMD2<Double>;let size:Double;let color:SceneVector3;let alpha:Double;let angle:Double;let progress:Double}

/// Offscreen native Metal implementation. Only the original kernels below are
/// compiled; downloaded shader text is inspected/hashed, never executed.
final class SceneAdvancedRenderer: @unchecked Sendable {
    static let shared = Result {try SceneAdvancedRenderer()}
    private let lock=NSLock()
    private let device:MTLDevice
    private let queue:MTLCommandQueue
    private var pipelines:[String:MTLRenderPipelineState]=[:]
    private let linear:MTLSamplerState
    private let repeatSampler:MTLSamplerState
    private let nearest:MTLSamplerState
    private let repeatNearest:MTLSamplerState
    private var textureCache:[String:(Data,MTLTexture)]=[:]
    private var contextID:UUID?
    private var simulationContexts:[UUID:[String:SceneParticleSimulation]]=[:]
    private var contextOrder:[UUID]=[]
    private var simulations:[String:SceneParticleSimulation]=[:]
    private var parallaxStates:[UUID:(runtime:Double,offset:SceneVector2)]=[:]
    private var textCache:[String:(SceneTextLayer,SceneVector2,SceneTextureAsset)]=[:]
    private struct Vertex {var xy:SIMD2<Float>;var uv:SIMD2<Float>}
    private struct Uniform {var tint:SIMD4<Float>;var misc:SIMD4<Float>}
    private struct ShaftUniform {
        var h0:SIMD4<Float>;var h1:SIMD4<Float>;var h2:SIMD4<Float>
        var shape:SIMD4<Float>;var feather:SIMD4<Float>;var noise:SIMD4<Float>;var color0:SIMD4<Float>;var color1:SIMD4<Float>;var mode:SIMD4<Float>
    }
    private static let source="""
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex {float2 xy;float2 uv;};
    struct V {float4 position [[position]];float2 uv;};
    struct U {float4 tint;float4 misc;};
    vertex V vertex_main(uint id [[vertex_id]],constant Vertex *v [[buffer(0)]]) {V o;o.position=float4(v[id].xy,0,1);o.uv=v[id].uv;return o;}
    fragment float4 image_main(V v [[stage_in]],texture2d<float> t [[texture(0)]],sampler s [[sampler(0)]],constant U &u [[buffer(0)]]) {float4 c=t.sample(s,v.uv);if(u.misc.w>0.0)c=mix(c,t.sample(s,v.uv+u.misc.yz),u.misc.w);return float4(c.rgb*u.tint.rgb*u.tint.a,c.a*u.tint.a);}
    fragment float4 water_main(V v [[stage_in]],texture2d<float> t [[texture(0)]],texture2d<float> normal [[texture(1)]],texture2d<float> back [[texture(2)]],sampler s [[sampler(0)]],constant U &u [[buffer(0)]]) {
        float4 c=t.sample(s,v.uv);float a=clamp(c.a*u.tint.a,0.0,1.0);
        float2 n=normal.sample(s,v.uv).xy*2.0-1.0;
        float2 screen=v.position.xy/float2(back.get_width(),back.get_height());
        float3 bg=back.sample(s,screen+n*u.misc.x*a).rgb;
        float3 modulation=c.a>0.00001?c.rgb/c.a:float3(1.0);
        return float4(bg*modulation*u.tint.rgb*a,a);
    }
    struct S {float4 h0;float4 h1;float4 h2;float4 shape;float4 feather;float4 noise;float4 color0;float4 color1;float4 mode;};
    float smooth_local(float a,float b,float x) {float t=clamp((x-a)/(b-a),0.0,1.0);return t*t*(3.0-2.0*t);}
    fragment float4 shaft_main(V v [[stage_in]],texture2d<float> noise [[texture(0)]],texture2d<float> gradient [[texture(1)]],sampler repeatS [[sampler(0)]],constant S &u [[buffer(0)]]) {
        float3 p=float3(v.uv,1);float3 h=float3(dot(u.h0.xyz,p),dot(u.h1.xyz,p),dot(u.h2.xyz,p));
        if(abs(h.z)<0.000001)discard_fragment();float2 c=h.xy/h.z;float mask=step(0.0,h.z);float2 scale=u.shape.xy;
        int mode=int(u.mode.x);int corner=int(u.mode.y);float2 ref=c;
        if(mode==1){float2 d=c-0.5;c.x=atan2(d.y,d.x)/6.283185+0.5;c.y=smooth_local(u.shape.z,1.0,length(d)*2.0);c.y=(c.y-0.0001)*1.00021;scale.x*=4;mask*=smooth_local(-0.00001+u.mode.z,u.mode.z+u.feather.x,c.x)*smooth_local(u.mode.w+0.00001,u.mode.w-u.feather.x,c.x)*smooth_local(0.50001,0.5-u.feather.y,abs(c.y-0.5));}
        else if(mode==2){float2 d=c;if(corner==1||corner==3)d.x=1.0-d.x;if(corner==2||corner==3)d.y=1.0-d.y;c.x=atan2(d.y,d.x)/6.283185*4.0;c.y=max(d.x,d.y);c.y+=noise.sample(repeatS,float2(c.x*0.054111*u.noise.x,0)).r*u.noise.y-u.noise.y*0.5;c.y=smooth_local(u.shape.z,1.0,c.y);scale.x*=4;mask*=smooth_local(0.50001,0.5-u.feather.x,abs(c.x-0.5))*smooth_local(0.50001,0.5-u.feather.y,abs(c.y-0.5));}
        else {mask*=smooth_local(0.50001,0.5-u.feather.x,abs(c.x-0.5))*smooth_local(0.50001,0.5-u.feather.y,abs(c.y-0.5));}
        ref=c;mask*=1.0-c.y;float2 c2=c;c*=float2(0.054111*scale.x,0.003111*scale.y);c2*=float2(0.07333*scale.x,0.005967111*scale.y);c+=u.noise.z*u.noise.w*float2(0.003,0.000375111);c2-=u.noise.z*u.noise.w*float2(0.0047111,0.0007399);
        float fx=pow(max(0.0,noise.sample(repeatS,c).r*noise.sample(repeatS,c2).r),u.shape.w);fx=smooth_local((1.0-u.feather.z)*0.29999,0.3+u.feather.z*0.7,fx)*mask;
        float3 grad=gradient.sample(repeatS,float2(ref.y,0)).rgb;float3 color=u.feather.w>0.5?(u.color1.w>0.5?grad.rrr:grad):mix(u.color0.rgb,u.color1.rgb,ref.y);
        fx=max(0.0,fx);return float4(color*u.color0.w*fx,clamp(fx,0.0,1.0));
    }
    fragment float4 threshold_main(V v [[stage_in]],texture2d<float> t [[texture(0)]],sampler s [[sampler(0)]],constant U &u [[buffer(0)]]) {float3 c=t.sample(s,v.uv).rgb;return float4(max(c-u.misc.x,0.0),1);}
    fragment float4 blur_main(V v [[stage_in]],texture2d<float> t [[texture(0)]],sampler s [[sampler(0)]],constant U &u [[buffer(0)]]) {float2 d=u.misc.xy;float3 c=t.sample(s,v.uv).rgb*0.227027;c+=(t.sample(s,v.uv+d*1.384615).rgb+t.sample(s,v.uv-d*1.384615).rgb)*0.316216;c+=(t.sample(s,v.uv+d*3.230769).rgb+t.sample(s,v.uv-d*3.230769).rgb)*0.070270;return float4(c,1);}
    float3 encode_srgb(float3 c){c=max(c,0.0);return select(1.055*pow(c,float3(1.0/2.4))-0.055,c*12.92,c<=0.0031308);}
    fragment float4 output_main(V v [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> bloom [[texture(1)]],sampler s [[sampler(0)]],constant U &u [[buffer(0)]]) {float inside=step(u.misc.x,v.uv.x)*step(u.misc.y,v.uv.y)*step(v.uv.x,u.misc.z)*step(v.uv.y,u.misc.w);float3 c=scene.sample(s,v.uv).rgb+bloom.sample(s,v.uv).rgb*u.tint.rgb*u.tint.a*inside;return float4(clamp(encode_srgb(c),0.0,1.0),1);}
    """
    init()throws {
        guard let d=MTLCreateSystemDefaultDevice(),let q=d.makeCommandQueue() else {throw SceneWallpaperFailure(message:"Advanced Scene requires Metal.")};device=d;queue=q
        let library=try d.makeLibrary(source:Self.source,options:nil)
        for name in ["image","water","shaft","threshold","blur","output"] {
            for additive in [false,true] {
                let desc=MTLRenderPipelineDescriptor();desc.vertexFunction=library.makeFunction(name:"vertex_main");desc.fragmentFunction=library.makeFunction(name:name+"_main")
                let color=desc.colorAttachments[0]!;color.pixelFormat=name=="output" ? .rgba8Unorm : .rgba16Float
                color.isBlendingEnabled=["image","water","shaft"].contains(name)
                color.sourceRGBBlendFactor = .one;color.destinationRGBBlendFactor=additive ? .one : .oneMinusSourceAlpha;color.sourceAlphaBlendFactor = .one;color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                pipelines[name+(additive ? "+":"")]=try d.makeRenderPipelineState(descriptor:desc)
            }
        }
        func sampler(_ mode:MTLSamplerAddressMode,_ filter:MTLSamplerMinMagFilter = .linear)throws->MTLSamplerState {let desc=MTLSamplerDescriptor();desc.minFilter=filter;desc.magFilter=filter;desc.sAddressMode=mode;desc.tAddressMode=mode;guard let s=d.makeSamplerState(descriptor:desc) else {throw SceneWallpaperFailure(message:"Advanced sampler allocation failed.")};return s}
        linear=try sampler(.clampToEdge);repeatSampler=try sampler(.repeat);nearest=try sampler(.clampToEdge,.nearest);repeatNearest=try sampler(.repeat,.nearest)
    }
    private func texture(_ asset:SceneTextureAsset,normal:Bool=false,convertChannels:Bool=false,colorKey:SceneColorKey?=nil)throws->MTLTexture {
        let effectKey=colorKey.map{"/key/\($0.color.x),\($0.color.y),\($0.color.z),\($0.alpha),\($0.fuzziness),\($0.tolerance)"} ?? ""
        let key=(contextID?.uuidString ?? "")+"/"+asset.path+(normal ? "/normal":"")+(convertChannels ? "/albedo-channels":"")+effectKey
        if let cached=textureCache[key],cached.0==asset.data {return cached.1}
        let width=asset.imageWidth,height=asset.imageHeight
        let image=try SceneWallpaperRenderer.decodedImage(asset)
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),let raw=context.data else {throw SceneWallpaperFailure(message:"Advanced texture decode allocation failed.")}
        context.setBlendMode(.copy);context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
        let input=raw.assumingMemoryBound(to:UInt8.self)
        var values=[Float16](repeating:0,count:width*height*4)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i=(y*width+x)*4,sourceAlpha=Double(input[i+3])/255
                var a=convertChannels ? Double(input[i+(asset.channelCount==1 ? 0:1)])/255 : sourceAlpha
                if let effect=colorKey {
                    guard asset.channelCount==4,!normal else {throw SceneWallpaperFailure(message:"Color-key requires a regular RGBA image source.")}
                    let rgb=(0..<3).map{sourceAlpha>0 ? min(1,Double(input[i+$0])/255/sourceAlpha):0}
                    let delta=abs(effect.color.x-rgb[0])+abs(effect.color.y-rgb[1])+abs(effect.color.z-rgb[2])
                    let t=min(1,max(0,(delta-effect.tolerance-0.001)/(0.001+effect.fuzziness)))
                    a *= effect.alpha+(1-effect.alpha)*t*t*(3-2*t)
                }
                for c in 0..<3 {
                    let straight:Double
                    if convertChannels {straight=asset.channelCount==1 ? 1:Double(input[i])/255}
                    else {straight=sourceAlpha>0 ? min(1,Double(input[i+c])/255/sourceAlpha):0}
                    // RG88 is a linear two-channel sample: grayscale R, alpha G.
                    let linear=(normal || (convertChannels && asset.channelCount==2)) ? straight : straight<=0.04045 ? straight/12.92 : pow((straight+0.055)/1.055,2.4)
                    values[i+c]=Float16(linear*(normal ? 1:a))
                };values[i+3]=Float16(normal ? 1:a)
            }
        }
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:width,height:height,mipmapped:false);desc.storageMode = .shared;desc.usage = .shaderRead
        guard let texture=device.makeTexture(descriptor:desc) else {throw SceneWallpaperFailure(message:"Advanced texture upload allocation failed.")}
        values.withUnsafeBytes{texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*8)}
        textureCache[key]=(asset.data,texture);return texture
    }
    private func target(_ width:Int,_ height:Int,output:Bool=false)throws->MTLTexture {
        let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:output ? .rgba8Unorm : .rgba16Float,width:width,height:height,mipmapped:false);desc.storageMode = .shared;desc.usage=[.renderTarget,.shaderRead]
        guard let texture=device.makeTexture(descriptor:desc) else {throw SceneWallpaperFailure(message:"Advanced framebuffer allocation failed.")};return texture
    }
    func render(_ inspection:SceneWallpaperInspection,pixelSize:CGSize,runtime:Double,cursor:SceneVector3?)throws->CGImage {
        lock.lock()
        defer {if let contextID {simulationContexts[contextID]=simulations};lock.unlock()}
        try Task.checkCancellation()
        guard runtime.isFinite,runtime>=0,runtime<=1e9,inspection.isRenderableSubset,pixelSize.width.isFinite,pixelSize.height.isFinite,pixelSize.width>=1,pixelSize.height>=1,pixelSize.width<=4096,pixelSize.height<=4096 else {throw SceneWallpaperFailure(message:"Invalid advanced Scene render input.")}
        let width=Int(pixelSize.width),height=Int(pixelSize.height)
        guard width*height<=16*1024*1024 else {throw SceneWallpaperFailure(message:"Advanced viewport pixel budget exceeded.")}
        if contextID != inspection.renderIdentity {
            if let contextID {simulationContexts[contextID]=simulations}
            contextID=inspection.renderIdentity;simulations=simulationContexts[inspection.renderIdentity] ?? [:]
            contextOrder.removeAll{$0==inspection.renderIdentity};contextOrder.append(inspection.renderIdentity)
            while contextOrder.count>3 {let oldest=contextOrder.removeFirst();simulationContexts.removeValue(forKey:oldest);textureCache=textureCache.filter{!$0.key.hasPrefix(oldest.uuidString+"/")};textCache=textCache.filter{!$0.key.hasPrefix(oldest.uuidString+"/")};parallaxStates.removeValue(forKey:oldest)}
        }
        var sourceAssets=inspection.textures
        for layer in inspection.layers {
            if let text=layer.textLayer {
                let key=inspection.renderIdentity.uuidString+"/"+layer.texturePath
                if let cached=textCache[key],cached.0==text,cached.1==layer.size {sourceAssets[layer.texturePath]=cached.2}
                else {let asset=try SceneTextRenderer.texture(text,size:layer.size,path:layer.texturePath);textCache[key]=(text,layer.size,asset);sourceAssets[layer.texturePath]=asset}
            }
            if let effect=layer.colorKey {guard [effect.color.x,effect.color.y,effect.color.z,effect.alpha].allSatisfy({$0.isFinite && (0...1).contains($0)}),effect.fuzziness.isFinite,(0...3).contains(effect.fuzziness),effect.tolerance.isFinite,(0...3).contains(effect.tolerance) else {throw SceneWallpaperFailure(message:"Invalid color-key state.")}}
        }
        let extraKeyPixels=inspection.layers.reduce(0){count,layer in count+(layer.colorKey != nil ? (sourceAssets[layer.texturePath].map{$0.imageWidth*$0.imageHeight} ?? 0):0)}
        let sourcePixels=sourceAssets.values.reduce(0){$0+$1.imageWidth*$1.imageHeight}+extraKeyPixels
        guard sourcePixels<=64*1024*1024,sourcePixels*8+width*height*28<=768*1024*1024 else {throw SceneWallpaperFailure(message:"Advanced conservative GPU/output memory budget exceeded.")}
        for layer in inspection.layers {
            try SceneScriptLayerState(layer:layer).validate()
            if let p=layer.particleSystem {try p.validate();for child in p.children {try child.system.validate();guard inspection.textures[child.texturePath] != nil else {throw SceneWallpaperFailure(message:"Missing static child texture.")}}}
            if layer.refractionAmount>0 {guard layer.refractionAmount.isFinite,layer.refractionAmount<=1,let normal=layer.normalTexturePath,inspection.textures[normal] != nil else {throw SceneWallpaperFailure(message:"Refraction requires its actual bounded normal texture.")}}
        }
        if let bloom=inspection.bloom {guard bloom.strength.isFinite,(0...10).contains(bloom.strength),bloom.threshold.isFinite,(0...100).contains(bloom.threshold),[bloom.tint.x,bloom.tint.y,bloom.tint.z].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw SceneWallpaperFailure(message:"Invalid advanced bloom state.")}}
        let normalPaths=Set(inspection.layers.compactMap(\.normalTexturePath)).union(inspection.layers.compactMap{$0.lightShaft?.noiseTexturePath})
        var textures:[String:MTLTexture]=[:]
        let gradientPaths=Set(inspection.layers.compactMap{$0.lightShaft?.gradientTexturePath})
        for (path,asset) in sourceAssets {textures[path]=try texture(asset,normal:normalPaths.contains(path),convertChannels:asset.channelCount<3 && !normalPaths.contains(path) && !gradientPaths.contains(path))}
        for layer in inspection.layers {if let effect=layer.colorKey,let asset=sourceAssets[layer.texturePath] {textures["__key_layer_\(layer.id)"]=try texture(asset,colorKey:effect)}}
        let scene=try target(width,height),snapshot=try target(width,height),out=try target(width,height,output:true)
        guard let command=queue.makeCommandBuffer() else {throw SceneWallpaperFailure(message:"Advanced command allocation failed.")}
        func encoder(_ target:MTLTexture,clear:Bool=false)->MTLRenderCommandEncoder? {
            let pass=MTLRenderPassDescriptor();let color=pass.colorAttachments[0]!;color.texture=target;color.loadAction=clear ? .clear:.load;color.storeAction = .store
            color.clearColor=MTLClearColor(red:inspection.clearColor.x,green:inspection.clearColor.y,blue:inspection.clearColor.z,alpha:1)
            return command.makeRenderCommandEncoder(descriptor:pass)
        }
        guard let clear=encoder(scene,clear:true) else {throw SceneWallpaperFailure(message:"Advanced clear allocation failed.")};clear.endEncoding()
        let camera=try inspection.camera.validatedTransform(),world=try SceneHierarchy.worldStates(layers:inspection.layers)
        var parallaxOffset=SceneVector2(x:0,y:0)
        if let effect=inspection.parallax {
            guard effect.amount.isFinite,(0...2).contains(effect.amount),effect.delay.isFinite,(0...10).contains(effect.delay),effect.mouseInfluence.isFinite,(0...2).contains(effect.mouseInfluence) else {throw SceneWallpaperFailure(message:"Invalid camera parallax state.")}
            var target=SceneVector2(x:0,y:0)
            if let cursor {
                guard [cursor.x,cursor.y,cursor.z].allSatisfy({$0.isFinite}) else {throw SceneWallpaperFailure(message:"Invalid parallax world cursor.")}
                let x=camera.a*cursor.x+camera.c*cursor.y+camera.tx-inspection.canvasSize.x/2,y=camera.b*cursor.x+camera.d*cursor.y+camera.ty-inspection.canvasSize.y/2
                target = .init(x:-max(-inspection.canvasSize.x/2,min(inspection.canvasSize.x/2,x))*effect.amount*effect.mouseInfluence,y:-max(-inspection.canvasSize.y/2,min(inspection.canvasSize.y/2,y))*effect.amount*effect.mouseInfluence)
            }
            var state=parallaxStates[inspection.renderIdentity] ?? (runtime:0,offset:.init(x:0,y:0))
            if runtime<state.runtime {state=(runtime:runtime,offset:.init(x:0,y:0))}
            let weight=effect.delay==0 ? 1:1-exp(-max(0,min(60,runtime-state.runtime))/effect.delay)
            parallaxOffset = .init(x:state.offset.x+(target.x-state.offset.x)*weight,y:state.offset.y+(target.y-state.offset.y)*weight)
            parallaxStates[inspection.renderIdentity]=(runtime:runtime,offset:parallaxOffset)
        }
        let fit=min(Double(width)/inspection.canvasSize.x,Double(height)/inspection.canvasSize.y),ox=(Double(width)-inspection.canvasSize.x*fit)/2,oy=(Double(height)-inspection.canvasSize.y*fit)/2
        func point(_ p:SIMD2<Double>,_ m:SceneAffineTransform)->SIMD2<Float> {let x=(m.a*p.x+m.c*p.y+m.tx)*fit+ox,y=(m.b*p.x+m.d*p.y+m.ty)*fit+oy;return .init(Float(x/Double(width)*2-1),Float(y/Double(height)*2-1))}
        func quad(_ corners:[SIMD2<Double>],_ m:SceneAffineTransform,uv0:SIMD2<Float> = .init(0,0),uv1:SIMD2<Float> = .init(1,1))->[Vertex] {
            let p=corners.map{point($0,m)}
            return [.init(xy:p[0],uv:.init(uv0.x,uv1.y)),.init(xy:p[1],uv:uv1),.init(xy:p[2],uv:uv0),.init(xy:p[1],uv:uv1),.init(xy:p[3],uv:.init(uv1.x,uv0.y)),.init(xy:p[2],uv:uv0)]
        }
        func rectangle(_ center:SIMD2<Double>,_ w:Double,_ h:Double,_ angle:Double)->[SIMD2<Double>] {let c=cos(angle),s=sin(angle);return [SIMD2(-w/2,-h/2),SIMD2(w/2,-h/2),SIMD2(-w/2,h/2),SIMD2(w/2,h/2)].map{center+SIMD2(c*$0.x-s*$0.y,s*$0.x+c*$0.y)}}
        var sampleWork=width*height
        func draw(_ vertices:[Vertex],_ e:MTLRenderCommandEncoder,targetWidth:Int?=nil,targetHeight:Int?=nil)throws {
            guard vertices.allSatisfy({[$0.xy.x,$0.xy.y,$0.uv.x,$0.uv.y].allSatisfy{$0.isFinite}}) else {throw SceneWallpaperFailure(message:"Nonfinite advanced draw geometry.")}
            let left=max(-1,vertices.map{$0.xy.x}.min() ?? 0),right=min(1,vertices.map{$0.xy.x}.max() ?? 0),bottom=max(-1,vertices.map{$0.xy.y}.min() ?? 0),top=min(1,vertices.map{$0.xy.y}.max() ?? 0)
            let work=Int(ceil(max(0,right-left)*Float(targetWidth ?? width)/2))*Int(ceil(max(0,top-bottom)*Float(targetHeight ?? height)/2))*4
            guard work<=512*1024*1024-sampleWork else {throw SceneWallpaperFailure(message:"Advanced sample-work budget exceeded before submission.")};sampleWork+=work
            vertices.withUnsafeBytes{e.setVertexBytes($0.baseAddress!,length:$0.count,index:0)};e.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count)}
        func uniform(_ e:MTLRenderCommandEncoder,_ tint:SceneVector3,_ opacity:Double,_ amount:Double=0,_ nextUV:SIMD2<Float> = .zero,_ frameBlend:Double=0) {var u=Uniform(tint:.init(Float(tint.x),Float(tint.y),Float(tint.z),Float(opacity)),misc:.init(Float(amount),nextUV.x,nextUV.y,Float(frameBlend)));e.setFragmentBytes(&u,length:MemoryLayout<Uniform>.stride,index:0)}
        var drawCount=0
        var activeEncoder:MTLRenderCommandEncoder?
        defer {activeEncoder?.endEncoding()}
        for layer in inspection.layers where !layer.isTransformOnly {
            try Task.checkCancellation()
            guard let state=world[layer.id],state.isVisible else {continue}
            let base=camera.concatenating(state.transform)
            let m=SceneAffineTransform(a:base.a,b:base.b,c:base.c,d:base.d,tx:base.tx+parallaxOffset.x*layer.parallaxDepth.x,ty:base.ty+parallaxOffset.y*layer.parallaxDepth.y)
            if layer.refractionAmount>0 {guard let blit=command.makeBlitCommandEncoder() else {throw SceneWallpaperFailure(message:"Refraction snapshot allocation failed.")};blit.copy(from:scene,to:snapshot);blit.endEncoding()}
            guard let e=encoder(scene) else {throw SceneWallpaperFailure(message:"Advanced draw encoder failed.")}
            activeEncoder=e
            e.setCullMode(.none);e.setFragmentSamplerState(linear,index:0)
            e.setScissorRect(.init(x:Int(floor(ox)),y:Int(floor(oy)),width:max(1,Int(ceil(Double(width)-ox)-floor(ox))),height:max(1,Int(ceil(Double(height)-oy)-floor(oy)))))
            if let shaft=layer.lightShaft {
                let h=try Self.inverseQuad(shaft.points)
                var u=ShaftUniform(h0:.init(Float(h[0]),Float(h[1]),Float(h[2]),0),h1:.init(Float(h[3]),Float(h[4]),Float(h[5]),0),h2:.init(Float(h[6]),Float(h[7]),Float(h[8]),0),shape:.init(Float(shaft.scale.x),Float(shaft.scale.y),Float(shaft.radius),Float(shaft.exponent)),feather:.init(Float(shaft.feather.x),Float(shaft.feather.y),Float(shaft.smoothness),Float(shaft.rendering)),noise:.init(Float(shaft.noiseScale),Float(shaft.noiseAmount),Float(runtime),Float(shaft.speed)),color0:.init(Float(shaft.colorStart.x),Float(shaft.colorStart.y),Float(shaft.colorStart.z),Float(shaft.intensity)),color1:.init(Float(shaft.colorEnd.x),Float(shaft.colorEnd.y),Float(shaft.colorEnd.z),(inspection.textures[shaft.gradientTexturePath]?.channelCount ?? 4)<3 ? 1:0),mode:.init(Float(shaft.mode),Float(shaft.corner),Float(shaft.startAngle),Float(shaft.endAngle)))
                e.setRenderPipelineState(pipelines["shaft+"]!);e.setFragmentBytes(&u,length:MemoryLayout<ShaftUniform>.stride,index:0);e.setFragmentTexture(textures[shaft.noiseTexturePath],index:0);e.setFragmentTexture(textures[shaft.gradientTexturePath] ?? textures[shaft.noiseTexturePath],index:1);e.setFragmentSamplerState(repeatSampler,index:0)
                try draw(quad(rectangle(.zero,layer.size.x,layer.size.y,0),m),e);drawCount+=1
            } else if let system=layer.particleSystem {
                var localCursor:SIMD2<Double>?
                if let cursor {let t=state.transform,det=t.a*t.d-t.b*t.c;if abs(det)>1e-9 {let x=cursor.x-t.tx,y=cursor.y-t.ty;localCursor = .init((t.d*x-t.c*y)/det,(-t.b*x+t.a*y)/det)}}
                func particles(_ spec:SceneSpriteParticleSystem,key:String,texture:String,normal:String?,blend:SceneImageBlend)throws {
                    let simulation=simulations[key] ?? SceneParticleSimulation(spec,seed:layer.id+key.utf8.reduce(0){$0+Int($1)});simulations[key]=simulation
                    let sprites=try simulation.evaluate(runtime:runtime,cursor:spec.controlPointFollowsMouse ? localCursor:.zero)
                    let sourceAsset=inspection.textures[texture]
                    guard let texture=textures[texture] else {throw SceneWallpaperFailure(message:"Missing advanced particle texture.")}
                    let water=layer.refractionAmount>0
                    e.setRenderPipelineState(pipelines[(water ? "water":"image")+(blend == .additive ? "+":"")]!);e.setFragmentTexture(texture,index:0);e.setFragmentTexture(normal.flatMap{textures[$0]},index:1);e.setFragmentTexture(snapshot,index:2)
                    let repeatUV=(sourceAsset?.flags ?? 0)&2==0,nearestUV=(sourceAsset?.flags ?? 0)&1 != 0
                    e.setFragmentSamplerState(nearestUV ? (repeatUV ? repeatNearest:nearest):(repeatUV ? repeatSampler:linear),index:0)
                    if spec.renderer == .rope {
                        guard sprites.count>=2 else {return}
                        var distance:Double=0
                        for i in 1..<sprites.count {
                            let a=sprites[i-1],b=sprites[i]
                            let p0=sprites[max(0,i-2)].position,p1=a.position,p2=b.position,p3=sprites[min(sprites.count-1,i+1)].position
                            func curve(_ t:Double)->SIMD2<Double> {0.5*(2*p1+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)}
                            let segments=max(1,spec.subdivision+1)
                            for segment in 0..<segments {
                                let t0=Double(segment)/Double(segments),t1=Double(segment+1)/Double(segments),t=(t0+t1)/2
                                let pa=curve(t0),pb=curve(t1),delta=pb-pa,length=simd_length(delta)
                                if length<1e-6 {continue}
                                let n=SIMD2(-delta.y,delta.x)/length,wa=max(0.01,a.size+(b.size-a.size)*t0)/2,wb=max(0.01,a.size+(b.size-a.size)*t1)/2
                                let corners=[pa-n*wa,pa+n*wa,pb-n*wb,pb+n*wb]
                                let scroll=spec.uvScrolling ? runtime*spec.rate:0
                                let start=distance/max(1,(a.size+b.size)/2)*spec.uvScale+scroll;distance+=length
                                let end=distance/max(1,(a.size+b.size)/2)*spec.uvScale+scroll
                                let tint=SceneVector3(x:a.color.x+(b.color.x-a.color.x)*t,y:a.color.y+(b.color.y-a.color.y)*t,z:a.color.z+(b.color.z-a.color.z)*t)
                                uniform(e,tint,(a.alpha+(b.alpha-a.alpha)*t)*layer.opacity,layer.refractionAmount)
                                try draw(quad(corners,m,uv0:.init(0,Float(end)),uv1:.init(1,Float(start))),e);drawCount+=1
                            }
                        }
                    } else {
                        for sprite in sprites where sprite.alpha>0 && sprite.size>0 {
                            let speed=simd_length(sprite.velocity),trail=spec.renderer == .spritetrail
                            let stretch=trail ? min(spec.trailMax,max(spec.trailMin,speed*spec.trailLength)):1
                            let angle=trail && speed>1e-9 ? atan2(-sprite.velocity.x,sprite.velocity.y):sprite.angle
                            var uv0=SIMD2<Float>(0,0),uv1=SIMD2<Float>(1,1),nextUV=SIMD2<Float>.zero,frameBlend:Double=0
                            if let animation=sourceAsset?.animation,let sourceAsset {
                                guard !animation.frames.isEmpty else {throw SceneWallpaperFailure(message:"Empty particle atlas.")}
                                // Official particle sheets run over each particle's lifetime;
                                // TEX frame durations are not a particle playback clock.
                                let framePosition=min(1,sprite.progress*spec.sequenceMultiplier)*Double(animation.frames.count-1)
                                let index=Int(floor(framePosition)),next=min(animation.frames.count-1,index+1)
                                let frame=animation.frames[index],following=animation.frames[next]
                                uv0 = .init(Float(Double(frame.x)+0.5)/Float(sourceAsset.imageWidth),Float(Double(frame.y)+0.5)/Float(sourceAsset.imageHeight))
                                uv1 = .init(Float(Double(frame.x+frame.width)-0.5)/Float(sourceAsset.imageWidth),Float(Double(frame.y+frame.height)-0.5)/Float(sourceAsset.imageHeight))
                                nextUV = .init(Float(following.x-frame.x)/Float(sourceAsset.imageWidth),Float(following.y-frame.y)/Float(sourceAsset.imageHeight))
                                frameBlend=framePosition-Double(index)
                            }
                            uniform(e,sprite.color,sprite.alpha*layer.opacity,layer.refractionAmount,nextUV,frameBlend)
                            try draw(quad(rectangle(sprite.position,sprite.size,sprite.size*max(0.001,stretch),angle),m,uv0:uv0,uv1:uv1),e);drawCount+=1
                        }
                    }
                }
                try particles(system,key:"\(layer.id)",texture:layer.texturePath,normal:layer.normalTexturePath,blend:layer.blend)
                for (i,child) in system.children.enumerated() {try particles(child.system,key:"\(layer.id)/\(i)",texture:child.texturePath,normal:child.normalTexturePath,blend:child.blend)}
            } else {
                guard let texture=textures[layer.colorKey != nil ? "__key_layer_\(layer.id)":layer.texturePath] else {throw SceneWallpaperFailure(message:"Missing advanced image/text texture.")}
                e.setRenderPipelineState(pipelines["image"+(layer.blend == .additive ? "+":"")]!);e.setFragmentTexture(texture,index:0);e.setFragmentSamplerState((inspection.textures[layer.texturePath]?.flags ?? 0)&1 != 0 ? nearest:linear,index:0);uniform(e,layer.tint,layer.opacity);try draw(quad(rectangle(.zero,layer.size.x,layer.size.y,0),m),e);drawCount+=1
            }
            e.endEncoding();activeEncoder=nil
            guard drawCount<=8192 else {throw SceneWallpaperFailure(message:"Advanced Scene draw budget exceeded.")}
        }
        let fullscreen=[Vertex(xy:.init(-1,-1),uv:.init(0,1)),.init(xy:.init(1,-1),uv:.init(1,1)),.init(xy:.init(-1,1),uv:.init(0,0)),.init(xy:.init(1,-1),uv:.init(1,1)),.init(xy:.init(1,1),uv:.init(1,0)),.init(xy:.init(-1,1),uv:.init(0,0))]
        func post(_ name:String,_ target:MTLTexture,_ t:MTLTexture,_ second:MTLTexture?=nil,_ u:Uniform)throws {
            guard let e=encoder(target,clear:true) else {throw SceneWallpaperFailure(message:"Postprocess encoder failed.")};defer {e.endEncoding()};e.setRenderPipelineState(pipelines[name]!);e.setFragmentTexture(t,index:0);e.setFragmentTexture(second ?? t,index:1);e.setFragmentSamplerState(linear,index:0);var u=u;e.setFragmentBytes(&u,length:MemoryLayout<Uniform>.stride,index:0);try draw(fullscreen,e,targetWidth:target.width,targetHeight:target.height)
        }
        var bloomTexture=scene,bloomUniform=Uniform(tint:.zero,misc:.zero)
        if let bloom=inspection.bloom,bloom.strength>0 {
            let bw=max(1,width/4),bh=max(1,height/4),a=try target(bw,bh),b=try target(bw,bh)
            // Threshold at native resolution before downsampling so subpixel
            // highlights are not averaged below the authored threshold.
            try post("threshold",snapshot,scene,nil,.init(tint:.zero,misc:.init(Float(bloom.threshold),0,0,0)))
            try post("blur",b,snapshot,nil,.init(tint:.zero,misc:.init(1/Float(width),0,0,0)))
            try post("blur",a,b,nil,.init(tint:.zero,misc:.init(0,1/Float(bh),0,0)))
            for radius:Float in [1,2,4] {try post("blur",b,a,nil,.init(tint:.zero,misc:.init(radius/Float(bw),0,0,0)));try post("blur",a,b,nil,.init(tint:.zero,misc:.init(0,radius/Float(bh),0,0)))}
            bloomTexture=a;bloomUniform.tint = .init(Float(bloom.tint.x),Float(bloom.tint.y),Float(bloom.tint.z),Float(bloom.strength))
        }
        bloomUniform.misc = .init(Float(ox/Double(width)),Float(oy/Double(height)),Float(1-ox/Double(width)),Float(1-oy/Double(height)))
        try post("output",out,scene,bloomTexture,bloomUniform)
        try Task.checkCancellation();command.commit();command.waitUntilCompleted()
        guard command.status == .completed else {throw SceneWallpaperFailure(message:"Advanced GPU frame failed: \(command.error?.localizedDescription ?? "unknown")")}
        try Task.checkCancellation()
        var data=Data(count:width*height*4);data.withUnsafeMutableBytes{out.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)}
        guard let provider=CGDataProvider(data:data as CFData),let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else {throw SceneWallpaperFailure(message:"Advanced output image creation failed.")};return image
    }
    private static func inverseQuad(_ points:[SceneVector2])throws->[Double] {
        guard points.count==4 else {throw SceneWallpaperFailure(message:"Lightshaft quad requires four corners.")}
        let p=points,dx1=p[1].x-p[2].x,dx2=p[3].x-p[2].x,dx3=p[0].x-p[1].x+p[2].x-p[3].x,dy1=p[1].y-p[2].y,dy2=p[3].y-p[2].y,dy3=p[0].y-p[1].y+p[2].y-p[3].y
        let divisor=dx1*dy2-dx2*dy1
        let g=abs(divisor)>1e-12 ? (dx3*dy2-dx2*dy3)/divisor:0,h=abs(divisor)>1e-12 ? (dx1*dy3-dx3*dy1)/divisor:0
        let a=p[1].x-p[0].x+g*p[1].x,b=p[3].x-p[0].x+h*p[3].x,c=p[0].x,d=p[1].y-p[0].y+g*p[1].y,e=p[3].y-p[0].y+h*p[3].y,f=p[0].y
        let determinant=a*(e-f*h)-b*(d-f*g)+c*(d*h-e*g)
        guard determinant.isFinite,abs(determinant)>1e-12 else {throw SceneWallpaperFailure(message:"Degenerate lightshaft perspective quad.")}
        return [(e-f*h),(c*h-b),(b*f-c*e),(f*g-d),(a-c*g),(c*d-a*f),(d*h-e*g),(b*g-a*h),(a*e-b*d)].map{$0/determinant}
    }
}
