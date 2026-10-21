import Foundation

struct SceneWallpaperFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
struct SceneVector2: Codable, Equatable, Sendable { let x: Double; let y: Double }
struct SceneVector3: Codable, Equatable, Sendable { let x: Double; let y: Double; let z: Double }
/// The bounded 2D part of Wallpaper Engine's orthographic camera. The camera
/// looks straight down -Z; XY eye movement, roll through `up`, and zoom form
/// an affine world-to-canvas transform. Near/far are preserved for fidelity,
/// but are 3D-only settings and therefore do not clip accepted 2D image quads.
struct SceneCamera2D: Equatable, Sendable {
    let center: SceneVector3
    let eye: SceneVector3
    let up: SceneVector3
    let zoom: Double
    let nearZ: Double
    let farZ: Double
    let cameraFade: Bool
    /// Accepted inputs contain both an origin-based 2D camera and a
    /// canvas-center-based camera encoding.
    let projectionOrigin: SceneVector2

    init(center: SceneVector3, eye: SceneVector3, up: SceneVector3, zoom: Double,
         nearZ: Double, farZ: Double, cameraFade: Bool, projectionOrigin: SceneVector2 = .init(x:0,y:0)) {
        self.center=center;self.eye=eye;self.up=up;self.zoom=zoom;self.nearZ=nearZ;self.farZ=farZ
        self.cameraFade=cameraFade;self.projectionOrigin=projectionOrigin
    }

    static let identity = Self(center:.init(x:0,y:0,z:-1),eye:.init(x:0,y:0,z:0),up:.init(x:0,y:1,z:0),zoom:1,nearZ:0.01,farZ:10_000,cameraFade:false)

    func validatedTransform() throws -> SceneAffineTransform {
        let values=[center.x,center.y,center.z,eye.x,eye.y,eye.z,up.x,up.y,up.z,zoom,nearZ,farZ,projectionOrigin.x,projectionOrigin.y]
        let length = hypot(up.x,up.y)
        guard values.allSatisfy({$0.isFinite && abs($0)<=1_000_000}), center.x == eye.x, center.y == eye.y,
              center.z < eye.z, up.z == 0, length.isFinite, length >= 1e-9,
              zoom > 0, zoom <= 1_000, nearZ > 0, farZ > nearZ else {
            throw SceneWallpaperFailure(message:"Invalid or unsupported 2D orthographic camera.")
        }
        let ux = up.x/length, uy = up.y/length
        let a=zoom*uy, b=zoom*ux, c = -zoom*ux, d=zoom*uy
        return .init(a:a,b:b,c:c,d:d,tx:projectionOrigin.x-(a*eye.x+c*eye.y),ty:projectionOrigin.y-(b*eye.x+d*eye.y))
    }
}
struct SceneDiagnostic: Codable, Equatable, Sendable {
    enum Severity: String, Codable, Sendable { case unsupported, invalid, missing }
    let severity: Severity
    let path: String
    let message: String
}
struct ScenePropertyBinding: Codable, Equatable, Sendable {
    let target: String
    let propertyKey: String
}
/// Deterministic local 2D sprite backend. Seeds, spawn timing and interpolation
/// are local conventions; Windows particle PRNG/numerical parity is unverified.
struct SceneSpriteParticleSystem: Codable, Sendable {
    enum Emitter: String, Codable, Sendable { case sphererandom, boxrandom }
    enum Renderer: String, Codable, Sendable { case sprite, spritetrail, rope }
    var renderer: Renderer = .sprite
    var trailLength:Double = 1
    var trailMin:Double = 0
    var trailMax:Double = 2
    var subdivision:Int = 0
    var uvScale:Double = 1
    var uvScrolling:Bool = false
    var sequenceMultiplier:Double = 1
    var turbulentSpeedMin:Double = 0
    var turbulentSpeedMax:Double = 0
    var turbulentScale:Double = 0.1
    var turbulentTimeScale:Double = 0.5
    var turbulentOffset:Double = 0
    var initialPhaseMin:Double = 0
    var initialPhaseMax:Double = 0
    var turbulenceSpeedMin:Double = 0
    var turbulenceSpeedMax:Double = 0
    var turbulenceTimeScale:Double = 1
    var turbulencePhaseMin:Double = 0
    var turbulencePhaseMax:Double = 0
    var turbulenceMask = SceneVector3(x:1,y:1,z:0)
    var oscillateAlphaMin:Double = 1
    var oscillateAlphaMax:Double = 1
    var oscillateFrequencyMin:Double = 0
    var oscillateFrequencyMax:Double = 0
    var controlPointAttract:Double = 0
    var controlPointThreshold:Double = 0
    var controlPointFollowsMouse:Bool = false
    var children:[SceneParticleChild] = []
    var emitter: Emitter = .sphererandom
    var rate: Double = 1
    var maximumCount: Int = 100
    var preRoll: Double = 0
    var radiusMin: Double = 0
    var radiusMax: Double = 0
    var boxMin = SceneVector3(x:0,y:0,z:0)
    var boxMax = SceneVector3(x:0,y:0,z:0)
    var directions = SceneVector3(x:1,y:1,z:0)
    var lifetimeMin: Double = 1
    var lifetimeMax: Double = 1
    var sizeMin: Double = 10
    var sizeMax: Double = 10
    var velocityMin = SceneVector3(x:0,y:0,z:0)
    var velocityMax = SceneVector3(x:0,y:0,z:0)
    var colorMin = SceneVector3(x:1,y:1,z:1)
    var colorMax = SceneVector3(x:1,y:1,z:1)
    var alphaMin: Double = 1
    var alphaMax: Double = 1
    var rotationMin: Double = 0
    var rotationMax: Double = 0
    var drag: Double = 0
    var gravity = SceneVector3(x:0,y:0,z:0)
    var fadeIn: Double = 0
    var fadeOut: Double = 1
    var sizeStart: Double = 1
    var sizeEnd: Double = 1
    var sizeChangeStart: Double = 0
    var colorStart = SceneVector3(x:1,y:1,z:1)
    var colorEnd = SceneVector3(x:1,y:1,z:1)
    var colorChangeStart: Double = 0
}
struct SceneParticleChild: Codable, Sendable {
    let system:SceneSpriteParticleSystem
    let texturePath:String
    let normalTexturePath:String?
    let blend:SceneImageBlend
}
struct SceneLightShaft: Codable, Sendable {
    var mode:Int = 0
    var corner:Int = 0
    var rendering:Int = 0
    var points:[SceneVector2] = []
    var speed:Double = 0.2
    var scale=SceneVector2(x:0.5,y:0.1)
    var smoothness:Double = 0.75
    var feather=SceneVector2(x:0.05,y:0.2)
    var radius:Double = 0.2
    var noiseScale:Double = 1
    var noiseAmount:Double = 0.33
    var intensity:Double = 1
    var exponent:Double = 1
    var colorStart=SceneVector3(x:1,y:1,z:1)
    var colorEnd=SceneVector3(x:0.5,y:0.8,z:1)
    var startAngle:Double = 0
    var endAngle:Double = 1
    var noiseTexturePath:String = "materials/util/noise.tex"
    var gradientTexturePath:String = "materials/gradient/gradient_iridescent.tex"
}
struct SceneBloom: Sendable {
    let strength:Double
    let threshold:Double
    let tint:SceneVector3
}
enum SceneImageBlend: String, Codable, Sendable { case translucent, additive }
struct SceneColorKey: Codable, Equatable, Sendable {
    let color:SceneVector3
    let alpha:Double
    let fuzziness:Double
    let tolerance:Double
}
struct SceneParallax: Sendable {
    let amount:Double
    let delay:Double
    let mouseInfluence:Double
}
struct SceneTextLayer: Codable, Equatable, Sendable {
    var value:String
    let fontData:Data
    let pointSize:Double
    let padding:SceneVector2
    let horizontalAlignment:String
    let verticalAlignment:String
}
struct SceneImageLayer: Codable, Sendable {
    let id: Int
    let name: String
    let modelPath: String
    let materialPath: String
    let texturePath: String
    /// Local 2D pixels, y-up. Parent transforms compose separately; image size is local quad extent.
    let origin: SceneVector3
    let anglesDegrees: SceneVector3
    let scale: SceneVector3
    let size: SceneVector2
    let tint: SceneVector3
    let opacity: Double
    let isVisible: Bool
    let bindings: [ScenePropertyBinding]
    let parentID: Int?
    /// A non-drawing node with only common transforms and visibility. Image-only
    /// fields remain fixed transport placeholders, never group author controls.
    let isTransformOnly: Bool
    let blend: SceneImageBlend
    let particleSystem: SceneSpriteParticleSystem?
    let lightShaft:SceneLightShaft?
    let normalTexturePath:String?
    let refractionAmount:Double
    let colorKey:SceneColorKey?
    let parallaxDepth:SceneVector2
    let textLayer:SceneTextLayer?

    init(id: Int, name: String, modelPath: String, materialPath: String, texturePath: String,
         origin: SceneVector3, anglesDegrees: SceneVector3, scale: SceneVector3, size: SceneVector2,
         tint: SceneVector3, opacity: Double, isVisible: Bool, bindings: [ScenePropertyBinding],
         parentID: Int? = nil, isTransformOnly: Bool = false, blend: SceneImageBlend = .translucent, particleSystem: SceneSpriteParticleSystem? = nil, lightShaft:SceneLightShaft? = nil, normalTexturePath:String? = nil, refractionAmount:Double = 0, colorKey:SceneColorKey? = nil, parallaxDepth:SceneVector2 = .init(x:0,y:0), textLayer:SceneTextLayer? = nil) {
        self.id = id; self.name = name; self.modelPath = modelPath; self.materialPath = materialPath
        self.texturePath = texturePath; self.origin = origin; self.anglesDegrees = anglesDegrees
        self.scale = scale; self.size = size; self.tint = tint; self.opacity = opacity
        self.isVisible = isVisible; self.bindings = bindings; self.parentID = parentID; self.isTransformOnly = isTransformOnly; self.blend = blend; self.particleSystem = particleSystem;self.lightShaft=lightShaft;self.normalTexturePath=normalTexturePath;self.refractionAmount=refractionAmount;self.colorKey=colorKey;self.parallaxDepth=parallaxDepth;self.textLayer=textLayer
    }
    private enum CodingKeys: String, CodingKey {
        case id, name, modelPath, materialPath, texturePath, origin, anglesDegrees, scale, size, tint, opacity, isVisible, bindings, parentID, isTransformOnly, blend, particleSystem, lightShaft, normalTexturePath, refractionAmount, colorKey, parallaxDepth, textLayer
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self,forKey:.id); name = try c.decode(String.self,forKey:.name)
        modelPath = try c.decode(String.self,forKey:.modelPath); materialPath = try c.decode(String.self,forKey:.materialPath)
        texturePath = try c.decode(String.self,forKey:.texturePath); origin = try c.decode(SceneVector3.self,forKey:.origin)
        anglesDegrees = try c.decode(SceneVector3.self,forKey:.anglesDegrees); scale = try c.decode(SceneVector3.self,forKey:.scale)
        size = try c.decode(SceneVector2.self,forKey:.size); tint = try c.decode(SceneVector3.self,forKey:.tint)
        opacity = try c.decode(Double.self,forKey:.opacity); isVisible = try c.decode(Bool.self,forKey:.isVisible)
        bindings = try c.decode([ScenePropertyBinding].self,forKey:.bindings)
        parentID = try c.decodeIfPresent(Int.self,forKey:.parentID)
        isTransformOnly = try c.decodeIfPresent(Bool.self,forKey:.isTransformOnly) ?? false
        blend = try c.decodeIfPresent(SceneImageBlend.self,forKey:.blend) ?? .translucent
        particleSystem = try c.decodeIfPresent(SceneSpriteParticleSystem.self,forKey:.particleSystem)
        lightShaft=try c.decodeIfPresent(SceneLightShaft.self,forKey:.lightShaft)
        normalTexturePath=try c.decodeIfPresent(String.self,forKey:.normalTexturePath)
        refractionAmount=try c.decodeIfPresent(Double.self,forKey:.refractionAmount) ?? 0
        colorKey=try c.decodeIfPresent(SceneColorKey.self,forKey:.colorKey)
        parallaxDepth=try c.decodeIfPresent(SceneVector2.self,forKey:.parallaxDepth) ?? .init(x:0,y:0)
        textLayer=try c.decodeIfPresent(SceneTextLayer.self,forKey:.textLayer)
    }
}
struct SceneTextureAnimation: Sendable {
    struct Frame: Sendable {let x:Int;let y:Int;let width:Int;let height:Int;let duration:Double}
    let frames:[Frame]
}
struct SceneEmbeddedVideo:Sendable {
    let data:Data
    let declaredWidth:Int
    let declaredHeight:Int
}
struct SceneTextureAsset: Sendable {
    enum Format: String, Codable, Sendable { case png, jpeg, rgba8888 }
    let path: String
    let format: Format
    /// TEX bit 0 requests nearest sampling; bit 1 requests clamped UVs.
    let flags: UInt32
    /// Original raw TEX channels; shader data textures must not be sRGB-decoded.
    var channelCount:Int = 4
    var animation:SceneTextureAnimation? = nil
    /// Only digest-pinned engine RG88 variants may carry AlphaChannelPriority bit19.
    var verifiedStorageVariant:Bool = false
    var video:SceneEmbeddedVideo? = nil
    /// Encoded image or tightly packed RGBA rows. No compressed TEX blocks are exposed as images.
    let data: Data
    let storageWidth: Int
    let storageHeight: Int
    /// Real top-left content rectangle in a possibly padded storage texture.
    let imageWidth: Int
    let imageHeight: Int
}
struct SceneWallpaperInspection: Sendable {
    let canvasSize: SceneVector2
    let clearColor: SceneVector3
    let camera: SceneCamera2D
    let layers: [SceneImageLayer]
    let textures: [String: SceneTextureAsset]
    let diagnostics: [SceneDiagnostic]
    let scriptProgram: SceneScriptProgram?
    let bloom:SceneBloom?
    let parallax:SceneParallax?
    let fidelityNotes:[String]
    let renderIdentity:UUID
    init(canvasSize: SceneVector2, clearColor: SceneVector3, camera: SceneCamera2D = .identity,
         layers: [SceneImageLayer], textures: [String: SceneTextureAsset], diagnostics: [SceneDiagnostic], scriptProgram: SceneScriptProgram? = nil, bloom:SceneBloom? = nil, fidelityNotes:[String] = [], renderIdentity:UUID = UUID(), parallax:SceneParallax? = nil) {
        self.canvasSize = canvasSize; self.clearColor = clearColor; self.camera = camera; self.layers = layers
        self.textures = textures; self.diagnostics = diagnostics; self.scriptProgram = scriptProgram
        self.bloom=bloom;self.fidelityNotes=fidelityNotes;self.renderIdentity=renderIdentity;self.parallax=parallax
    }
    var requiresAdvancedRendering:Bool {bloom != nil || parallax != nil || layers.contains{$0.colorKey != nil || $0.textLayer != nil} || textures.values.contains{$0.video != nil || $0.animation != nil || $0.channelCount<3} || layers.contains{layer in
        guard let p=layer.particleSystem else {return layer.lightShaft != nil || layer.refractionAmount>0}
        return p.renderer != .sprite || p.turbulentSpeedMax>0 || p.turbulenceSpeedMax>0 || p.controlPointAttract != 0 || !p.children.isEmpty || p.oscillateFrequencyMax>0 || layer.refractionAmount>0
    }}
    var isRenderableSubset: Bool { diagnostics.isEmpty && !textures.values.contains{$0.video != nil} && layers.contains { !$0.isTransformOnly } && layers.allSatisfy { $0.isTransformOnly || $0.textLayer != nil || ($0.lightShaft != nil ? textures[$0.lightShaft!.noiseTexturePath] != nil && ($0.lightShaft!.rendering == 0 || textures[$0.lightShaft!.gradientTexturePath] != nil) : textures[$0.texturePath] != nil) } }
}
struct SceneReadLimits: Sendable {
    var maximumArchiveBytes: UInt64 = 2 * 1024 * 1024 * 1024
    var maximumEntries = 20_000
    var maximumIndexBytes = 16 * 1024 * 1024
    var maximumEntryBytes = 64 * 1024 * 1024
    var maximumJSONBytes = 4 * 1024 * 1024
    var maximumLayers = 512
    var maximumTextureBytes = 128 * 1024 * 1024
    var maximumTexturePixels = 32 * 1024 * 1024
    var maximumTotalTexturePixels = 64 * 1024 * 1024
}

struct SceneByteCursor {
    let data: Data
    var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SceneWallpaperFailure(message: "Truncated binary scene data.") }
        let result = data.subdata(in: offset..<offset+count); offset += count; return result
    }
    mutating func u32() throws -> UInt32 {
        let value = try bytes(4)
        return value.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
    }
    mutating func cString(maximum: Int = 16) throws -> String {
        var value = Data()
        for _ in 0...maximum {
            let byte = try bytes(1)[0]
            if byte == 0, let text = String(data: value, encoding: .utf8) { return text }
            value.append(byte)
        }
        throw SceneWallpaperFailure(message: "Invalid or oversized binary section marker.")
    }
}

struct SceneSpriteParticle: Sendable {
    let position: SceneVector2
    let size: Double
    let rotationRadians: Double
    let color: SceneVector3
    let alpha: Double
}
extension SceneSpriteParticleSystem {
    func validate() throws {
        let scalar=[sequenceMultiplier,trailLength,trailMin,trailMax,uvScale,turbulentSpeedMin,turbulentSpeedMax,turbulentScale,turbulentTimeScale,turbulentOffset,initialPhaseMin,initialPhaseMax,turbulenceSpeedMin,turbulenceSpeedMax,turbulenceTimeScale,turbulencePhaseMin,turbulencePhaseMax,oscillateAlphaMin,oscillateAlphaMax,oscillateFrequencyMin,oscillateFrequencyMax,controlPointAttract,controlPointThreshold,rate,preRoll,radiusMin,radiusMax,lifetimeMin,lifetimeMax,sizeMin,sizeMax,alphaMin,alphaMax,rotationMin,rotationMax,drag,fadeIn,fadeOut,sizeStart,sizeEnd,sizeChangeStart,colorChangeStart]
        let vectors=[turbulenceMask,boxMin,boxMax,directions,velocityMin,velocityMax,colorMin,colorMax,gravity,colorStart,colorEnd]
        guard scalar.allSatisfy({$0.isFinite && abs($0)<=100_000}),vectors.allSatisfy({[$0.x,$0.y,$0.z].allSatisfy{$0.isFinite && abs($0)<=100_000}}),
              (0...100).contains(sequenceMultiplier),(0...8).contains(subdivision),children.count<=8,children.allSatisfy({$0.system.children.isEmpty}),trailMin>=0,trailMax>=trailMin,uvScale>=0,controlPointThreshold>=0,turbulentSpeedMin>=0,turbulentSpeedMax>=turbulentSpeedMin,turbulenceSpeedMin>=0,turbulenceSpeedMax>=turbulenceSpeedMin,[oscillateAlphaMin,oscillateAlphaMax].allSatisfy({(0...1).contains($0)}),
              (0...2048).contains(maximumCount),(0...1000).contains(rate),(0...60).contains(preRoll),
              lifetimeMin>0,lifetimeMax>=lifetimeMin,lifetimeMax<=60,sizeMin>0,sizeMax>=sizeMin,sizeMax<=16_384,
              radiusMin>=0,radiusMax>=radiusMin,drag>=0,drag<=1000,
              [alphaMin,alphaMax,fadeIn,fadeOut,sizeChangeStart,colorChangeStart].allSatisfy({(0...1).contains($0)}),
              alphaMax>=alphaMin,fadeOut>=fadeIn,sizeStart>=0,sizeEnd>=0,
              [colorMin,colorMax,colorStart,colorEnd].allSatisfy({[$0.x,$0.y,$0.z].allSatisfy{(0...1).contains($0)}}),
              directions.z==0,boxMin.z==0,boxMax.z==0,velocityMin.z==0,velocityMax.z==0,gravity.z==0,
              boxMin.x<=boxMax.x,boxMin.y<=boxMax.y else {throw SceneWallpaperFailure(message:"Invalid/unsafe 2D sprite particle parameters.")}
    }
    /// Stateless bounded evaluation makes pause/reload/seek deterministic and
    /// prevents accumulated timer work. It does not reproduce the Windows RNG.
    func sprites(runtime:Double,seed:Int)throws->[SceneSpriteParticle] {
        try validate()
        guard runtime.isFinite,runtime>=0,runtime<=1_000_000_000 else {throw SceneWallpaperFailure(message:"Invalid particle runtime.")}
        if rate==0 || maximumCount==0 {return []}
        let time=runtime+preRoll,last=Int64(floor(time*rate))
        // Older births cannot still be alive; work is bounded before iteration.
        let count=min(maximumCount,Int(min(Double(last+1),ceil(lifetimeMax*rate)+1)))
        var output:[SceneSpriteParticle]=[]
        for offset in (0..<count).reversed() {
            try Task.checkCancellation()
            let index=last-Int64(offset),age=time-Double(index)/rate
            var state=UInt64(truncatingIfNeeded:seed) &* 0x9e3779b97f4a7c15 ^ UInt64(truncatingIfNeeded:index)
            func random()->Double {
                state &+= 0x9e3779b97f4a7c15
                var n=state;n=(n ^ (n>>30)) &* 0xbf58476d1ce4e5b9;n=(n ^ (n>>27)) &* 0x94d049bb133111eb;n ^= n>>31
                return Double(n>>11)/9_007_199_254_740_992
            }
            func mix(_ a:Double,_ b:Double,_ t:Double)->Double {a+(b-a)*t}
            let life=mix(lifetimeMin,lifetimeMax,random())
            if age<0 || age>=life {continue}
            let progress=age/life
            var x:Double,y:Double
            switch emitter {
            case .sphererandom:
                let angle=random()*2 * .pi,radius=sqrt(mix(radiusMin*radiusMin,radiusMax*radiusMax,random()))
                x=cos(angle)*radius*directions.x;y=sin(angle)*radius*directions.y
            case .boxrandom:
                x=mix(boxMin.x,boxMax.x,random())*directions.x;y=mix(boxMin.y,boxMax.y,random())*directions.y
            }
            let vx=mix(velocityMin.x,velocityMax.x,random()),vy=mix(velocityMin.y,velocityMax.y,random())
            let velocityIntegral:Double,gravityIntegral:Double
            if drag<1e-8 {velocityIntegral=age;gravityIntegral=age*age/2}
            else {velocityIntegral = -expm1(-drag*age)/drag;gravityIntegral=(age-velocityIntegral)/drag}
            x += vx*velocityIntegral+gravity.x*gravityIntegral;y += vy*velocityIntegral+gravity.y*gravityIntegral
            let sizeT=sizeChangeStart>=1 ? 0 : min(1,max(0,(progress-sizeChangeStart)/(1-sizeChangeStart)))
            let size=mix(sizeMin,sizeMax,random())*mix(sizeStart,sizeEnd,sizeT)
            let rotation=mix(rotationMin,rotationMax,random())
            let colorT=colorChangeStart>=1 ? 0 : min(1,max(0,(progress-colorChangeStart)/(1-colorChangeStart)))
            let color=SceneVector3(x:mix(colorMin.x,colorMax.x,random())*mix(colorStart.x,colorEnd.x,colorT),y:mix(colorMin.y,colorMax.y,random())*mix(colorStart.y,colorEnd.y,colorT),z:mix(colorMin.z,colorMax.z,random())*mix(colorStart.z,colorEnd.z,colorT))
            var alpha=mix(alphaMin,alphaMax,random())
            if fadeIn>0 {alpha *= min(1,progress/fadeIn)}
            if fadeOut<1 {alpha *= min(1,max(0,(1-progress)/(1-fadeOut)))}
            if size>0 && alpha>0 {output.append(.init(position:.init(x:x,y:y),size:size,rotationRadians:rotation,color:color,alpha:alpha))}
        }
        return output
    }
}
