import Cocoa
import MetalKit
import CryptoKit

/// A particle system as the simulation and the draw read it: its emitter, its compiled program
/// (`ParticleProgram`: initializers and operators in authored order), control points and renderer.
/// `ParticleSystemBuilder` makes it from the particle json with WE's defaults.
struct SceneMetalParticleSystem {
    var source: SceneMetalTextureSource
    /// Index of the object in scene.json; systems draw between layers in that order.
    var order = 0
    /// The emitter's scene position at load. With `emitterLinear` it is the emitter object's
    /// authored world transform, which the simulation uses unless the renderer supplies a live one.
    let origin: SIMD2<Float>
    let emissionRate: Float
    let maximumParticleCount: Int
    /// The emitter's shape (`sphererandom`, `boxrandom`).
    var emitter = ParticleEmitterShape()
    /// Initializers and operators, in authored order.
    var program = ParticleProgram()
    /// The system's eight control points, by index.
    var controlPoints: [ParticleControlPoint] = ParticleControlPoint.defaults
    /// The first renderer's name (`additionalRenderers` has the others).
    var rendererName: String
    /// The trail renderers' `length`: seconds of history a `ropetrail` keeps; the `spritetrail`
    /// shader's stretch per unit of speed (`ParticleMaterialPlanBuilder.trailLengths`).
    var trailLength: Float
    /// `spritetrail`'s `maxlength` and `minlength`: the stretch's limits.
    var trailLengthLimits = SIMD2<Float>(10, 0)
    /// The renderer's `orientation`, `axis` and `flags`: the axes its sprites and ribbons face along.
    var orientation = ParticleOrientation()
    /// A rope's `uvscale`, `uvsmoothing` and `uvscrolling`.
    var ropeUV = ParticleRopeUV()
    /// `ropetrail`'s `segments`: samples of history per particle.
    var trailSegments: Int
    /// `subdivision`: spline points per rope segment (the `TRAILSUBDIVISION` combo).
    var ropeSubdivision: Int
    var fadeTrailAlpha: Bool
    var fadeTrailSize: Bool
    let spriteSheet: SpriteSheet?
    let animationMode: String
    let sequenceMultiplier: Float
    let opacityMultiplier: Float
    let refractive: Bool
    let blending: String
    /// The system's material for WE's own particle shaders; nil keeps the built-in particle draw.
    var material: ParticleMaterialPlan? = nil
    /// Texture 0 for the built-in draw when it can't sample `source` as it is
    /// (`ParticleFallbackTexture`).
    var fallbackSource: SceneMetalTextureSource? = nil
    /// The emitter object's id in the scene hierarchy; the renderer moves the emitter with that
    /// object's live transform (parents, scripts and animations included).
    var objectID: String? = nil
    /// The emitter's world scale and rotation at load (see `origin`).
    var emitterLinear = matrix_identity_float2x2
    /// `flags` bit 0: the system simulates in the scene (WE's world space); spawned particles stay
    /// where they are when the emitter moves. Otherwise they live in the emitter's space and move,
    /// turn and scale with it.
    var worldSpace = false
    /// `flags` bit 2 (4): the system is drawn through a perspective camera even in an orthographic
    /// scene (WE's temporary camera, 0x140236761), so its particles' depth shows.
    var perspective = false
    /// The emitter's `instantaneous` burst: particles spawned at once when the emitter starts (and
    /// each period, when periodic).
    var instantaneous = 0
    /// When the emitter emits: `delay`, `duration`, periodic emission, one per frame.
    var emitterTiming = ParticleEmitterTiming()
    /// Set for a child system: how it hangs off its parent.
    var link: ParticleChildLink? = nil
    /// The depth part of its `children` links (`ParticleLinkSpace.space`); identity for a root.
    var linkSpace = matrix_identity_float4x4
    /// The object's `instanceoverride` as resolved at load. Emission rate, maximum, size, alpha,
    /// lifetime, speed and colour above are authored; these scale them every frame.
    var overrides = SceneParticleOverrides()
    /// The `instanceoverride` again when a field is bound to a user property: resolved every
    /// frame instead of `overrides`.
    var liveOverrides: WEInstanceOverride? = nil
    /// The user's particle budget's factor on the maximum and every emitter's rate (`ParticleBudget`),
    /// applied like the `count` and `rate` overrides but never switched off by the system's flags;
    /// 1 when the scene fits the budget.
    var budgetScale: Float = 1
    /// The instance overrides the system's `flags` switch off (`SceneParticleOverrides.Parts`).
    var ignoredOverrides: SceneParticleOverrides.Parts = []
    /// The emitter's audio response, on its rate.
    var rateAudio: ParticleAudioResponse? = nil
    /// The emitters after the first, in authored order. WE runs every emitter of a system, each
    /// with its own rate, burst and timing (`wallpaper64.exe` 0x1402378a0 walks the emitter records);
    /// the fields above (`emitter`, `emissionRate`, `instantaneous`, `emitterTiming`, `rateAudio`) are
    /// the first's.
    var extraEmitters: [ParticleEmitter] = []
    /// The system has event children, which read its spawns and deaths.
    var hasEventChildren = false
    /// `starttime`: seconds WE simulates before the first frame.
    var startTime: Float = 0
    /// The layers the `layerimage` emitters emit from, by the emitter's ordinal among them (the
    /// object's `emitterimage` dependencies); the renderer samples each layer's image into its points.
    var emitterImages: [ParticleEmitterImage] = []
    /// The objects the `collisionmodel` operators collide with, by the operator's dependency
    /// index (`ParticleCollision.Shape.model`, the object's `collisionmodel` dependencies).
    var collisionModels: [Int: String] = [:]
    /// The system's renderers after the first, in authored order. WE draws every renderer from the
    /// one simulation; the renderer draws each from this system's particles
    /// (`ParticleSystemRuntime.simulation`).
    var additionalRenderers: [ParticleRendererDraw] = []
    /// The history the simulation keeps when a renderer after the first is the `ropetrail`, or
    /// when this is such a renderer's draw; nil takes it from the system's own renderer.
    var sharedHistory: ParticleTrailHistory? = nil

    /// The trail history the simulation keeps (`ParticleTrailHistory`).
    var trailHistory: ParticleTrailHistory {
        sharedHistory ?? ParticleTrailHistory(kept: rendererName == "ropetrail", length: trailLength, segments: trailSegments)
    }

    /// The system as `renderer` draws it: the same system with that renderer's fields and
    /// material, and the history the simulation keeps.
    func drawing(_ renderer: ParticleRendererDraw) -> SceneMetalParticleSystem {
        var system = self
        system.sharedHistory = trailHistory
        system.additionalRenderers = []
        system.apply(renderer)
        system.material = renderer.material
        return system
    }

    /// Takes `renderer`'s fields (not its material).
    mutating func apply(_ renderer: ParticleRendererDraw) {
        rendererName = renderer.name
        trailLength = renderer.trailLength
        trailLengthLimits = renderer.trailLengthLimits
        trailSegments = renderer.trailSegments
        ropeSubdivision = renderer.ropeSubdivision
        fadeTrailAlpha = renderer.fadeTrailAlpha
        fadeTrailSize = renderer.fadeTrailSize
        orientation = renderer.orientation
        ropeUV = renderer.ropeUV
    }

    /// Runs as instances (`ParticleChildLink`).
    var isInstanced: Bool { link?.instanced == true }

    /// Every emitter, the first included, in the order WE runs them.
    var emitters: [ParticleEmitter] {
        [ParticleEmitter(shape: emitter, rate: emissionRate, instantaneous: instantaneous, timing: emitterTiming,
                         audio: rateAudio)] + extraEmitters
    }

    /// The emitter's authored world transform.
    var authoredWorld: SceneAffineTransform {
        SceneAffineTransform(linear: emitterLinear, translation: origin)
    }

    /// Whether the program has an operator of `kind`.
    func has(_ kind: ParticleOperatorKind) -> Bool { program.operators.contains { $0.kind == kind } }
}

/// One emitter of a system: its shape, rate, `instantaneous` burst, timing and audio response.
struct ParticleEmitter {
    var shape = ParticleEmitterShape()
    /// Particles a second (WE's default 10, 0x1401b8e59).
    var rate: Float = 10
    var instantaneous = 0
    var timing = ParticleEmitterTiming()
    var audio: ParticleAudioResponse?
}

/// An emitter's shape and launch speed (`sphererandom`, `boxrandom`, `layerimage`), in the
/// system's space. WE's spawn code: `wallpaper64.exe` 0x140237c14 (sphere), 0x14023847f (box),
/// 0x140238c45 (layer image).
struct ParticleEmitterShape: Equatable {
    enum Kind: UInt32 { case sphere = 0, box, image }

    var kind = Kind.sphere
    /// `origin`, added to the control point's position.
    var origin = SIMD3<Float>.zero
    /// `directions`: scales the spawn offset per axis.
    var directions = SIMD3<Float>(1, 1, 0)
    /// `distancemin` and `distancemax`: a sphere's radii (x), a box's half extents.
    var distanceMinimum = SIMD3<Float>.zero
    var distanceMaximum = SIMD3<Float>(256, 256, 0)
    /// `speedmin`, `speedmax`: speed away from the emitter's centre; a `layerimage` emitter's
    /// share of its layer's motion with `inheritsLayerMotion`.
    var speed = SIMD2<Float>.zero
    /// `sign`, when `flags` bit 0 applies it: forces an axis of the offset positive (> 0) or
    /// negative (< 0).
    var sign = SIMD3<Float>.zero
    var appliesSign = false
    /// `cone`: the sphere's spread around its +x axis, 0 a full sphere, 1 one direction.
    var cone: Float = 0
    /// `controlpoint`: where the emitter sits.
    var controlPoint = 0
    /// A `layerimage` emitter's ordinal among the system's `layerimage` emitters: the index of its
    /// `emitterimage` dependency (`SceneMetalParticleSystem.emitterImages`).
    var imageIndex = 0
    /// A `layerimage` emitter's `flags` 0x10000 (WE's default): the particle's base colour takes
    /// the image's colour where it spawns (0x140239765).
    var takesImageColor = true
    /// A `layerimage` emitter's `flags` 0x80000: the spawn moves by a random offset between
    /// `offsetmin` and `offsetmax` (`distanceMinimum`, `distanceMaximum`; 0x140238fad).
    var offsetsRandomly = false
    /// A `layerimage` emitter's `flags` 0x20000, "update emission bitmap periodically": once a
    /// second of emitting, its points are made again from the layer's texture as it is then
    /// (0x140238d4f; `ParticleEmitterImageResampler`).
    var resamplesImage = false
    /// A `layerimage` emitter's `flags` 0x40000, "inherit layer motion": a spawn launches with its
    /// point's motion since the last step, scaled by `speed` (0x1402397d3).
    var inheritsLayerMotion = false
}

/// The layer a `layerimage` emitter emits from and the points it picks among
/// (`ParticleEmitterImagePoints`).
struct ParticleEmitterImage: Equatable {
    /// The layer's object id.
    var layerID: String
    /// Filled by the renderer when it has the layer's texture: one point per texel of the image
    /// reduced to a quarter (x, y in the layer's pixels from its centre, y up; the texel's
    /// colour packed as 0xRRGGBB; on a Puppet Warp layer the bone it follows, −1 for none,
    /// `ParticleEmitterImageBones`).
    var points: [SIMD4<Int32>] = []
}

/// A control point (WE's `controlpoint` array entry, by index; `wallpaper64.exe` updates them each
/// frame at 0x14022e3e0).
struct ParticleControlPoint: Equatable {
    /// `offset` (or the object's `controlpoint<n>` override), y up, z the depth: in the system's
    /// space, or in the scene when `worldSpace` (0x14022cdc0 keeps all three).
    var offset = SIMD3<Float>.zero
    /// Flag 1: sits on the cursor.
    var followsCursor = false
    /// Flag 2 (not for control point 0): `offset` is a scene position.
    var worldSpace = false
    /// Flag 4: copies its parent system's control point `parentcontrolpoint`.
    var parentControlPoint: Int?
    /// Flag 8 ("raw value", with flag 4): the parent's point as it is in the parent's space, not
    /// carried into this system's (0x14022e6b3 copies the parent's matrix unchanged).
    var parentRawValue = false

    static let count = 8
    static let defaults = [ParticleControlPoint](repeating: ParticleControlPoint(), count: count)
}

struct SpriteSheet {
    let columns: Int
    let rows: Int
    let frames: Int
    let duration: Float
}

extension SpriteSheet {
    /// A `.tex-json` `spritesheetsequences` entry's grid: `frames` frames of `frameSize` pixels,
    /// row by row across a texture of `textureSize` pixels (`SceneMetalTextureSource.sheetPixelSize`).
    init(frames: Int, frameSize: SIMD2<Double>, duration: Float, textureSize: SIMD2<Double>) {
        // Saturating: a zero or non-finite frame size from the file gives a one-cell grid axis
        // rather than stopping the process.
        let columns = max(1, min(frames, Int(saturating: (textureSize.x / frameSize.x).rounded())))
        let authoredRows = max(1, Int(saturating: (textureSize.y / frameSize.y).rounded()))
        let rows = max(authoredRows, Int(ceil(Double(frames) / Double(columns))))
        self.init(columns: columns, rows: rows, frames: frames, duration: duration)
    }

    /// The sheet an animated `.tex`'s `TEXS` frames lay out on its one atlas: what WE's runtime
    /// reads, as the resource compiler bakes a `.tex-json`'s `spritesheetsequences` into `TEXS`
    /// (only `resourcecompiler64.exe` names that key, never `wallpaper64.exe`), so a Workshop
    /// texture ships no `.tex-json`. `frames` are in the loaded atlas's pixels, as `textureSize`
    /// is. The duration is the frames' times; frames without times (`TEXS0002`) take the
    /// `.tex-json` default of a second. Nil without frames or with several atlases (a GIF).
    init?(texFrames frames: [TEXAnimationFrame], textureSize: SIMD2<Double>) {
        guard let first = frames.first, first.width > 0, first.height > 0,
              frames.allSatisfy({ $0.imageIndex == first.imageIndex }) else { return nil }
        let time = frames.reduce(Float(0)) { $0 + max($1.duration, 0) }
        self.init(frames: frames.count, frameSize: SIMD2(Double(first.width), Double(first.height)),
                  duration: time > 0 ? time : 1, textureSize: textureSize)
    }
}

extension ParticleEmitterImage {
    /// The layers a particle object's `emitterimage` dependencies name, by their `index` (the
    /// `layerimage` emitter's ordinal; WE parses them at 0x14022b1d9 and binds them by index at
    /// 0x140238d43). An index nothing names has no layer and emits nothing, as in WE.
    static func bound(_ dependencies: [WEObjectDependency]) -> [ParticleEmitterImage] {
        var images: [ParticleEmitterImage] = []
        for case let .link(id, type, index) in dependencies where type?.lowercased() == "emitterimage" {
            let slot = max(index ?? 0, 0)
            guard slot < 64 else { continue }
            while images.count <= slot { images.append(ParticleEmitterImage(layerID: "")) }
            images[slot].layerID = String(id)
        }
        return images
    }
}
