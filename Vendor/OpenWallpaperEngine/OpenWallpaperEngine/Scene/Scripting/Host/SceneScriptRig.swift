import simd

/// A script's call on a Puppet Warp image's skeleton (`IImageLayer`'s animation-layer and bone
/// API, `IAnimationLayer`; docs/models-plan.md §2.8, §4.3 P2), handed to the renderer's
/// `ScenePuppetAnimator` in call order. Matrices are column-vector (`p′ = M · p`), which is the
/// memory of WE's row-vector `Mat4`.
enum SceneScriptRigCommand: Equatable {
    /// `createAnimationLayer`/`playSingleAnimation`'s config (the d.ts: `blendin`, `blendout`,
    /// `blendtime`, `autosort`; and the authored layer keys a JSON config may carry).
    struct LayerConfig: Equatable {
        var name: String?
        var additive = false
        var blendIn = false
        var blendOut = false
        var autosort = false
        var blendTime: Float = 0.5
        var rate: Float = 1
        var blend: Float = 1
        var visible = true
    }

    enum LayerField: Int, Equatable {
        case rate = 0, blend = 1, visible = 2
    }

    enum Playback: Equatable {
        case play, pause, stop
        case setFrame(Float)
    }

    /// A layer playing the clip named `clip`, with the key the script gave it; `singlePlay`
    /// removes it once its clip finished.
    case createLayer(key: Int, clip: String, config: LayerConfig, singlePlay: Bool)
    case destroyLayer(key: Int)
    case setLayer(key: Int, field: LayerField, value: Float)
    case playback(key: Int, Playback)
    /// `setLocalBoneTransform` (and the angles and origin setters, composed by the script side).
    case setLocal(bone: Int, matrix: simd_float4x4)
    /// `setBoneTransform`, in the rig's model space (the renderer takes the object's world off).
    case setWorld(bone: Int, matrix: simd_float4x4)
    /// `setBlendShapeWeight` on the rig's first mesh's target `index` (0x1402105c0).
    case setBlendShape(index: Int, weight: Float)
    /// `applyBonePhysicsImpulse` (0x140210990): `linear` joins the bone's velocity and its
    /// angular velocity turns by the Euler angles `angularDegrees` (docs/models-plan.md §2.14).
    case physicsImpulse(bone: Int, linear: SIMD3<Float>, angularDegrees: SIMD3<Float>)
    /// `resetBonePhysicsSimulation` (0x140210e10): the bone's physics state as it loaded.
    case resetPhysics(bone: Int)
}

/// A puppet's or model's skeleton as this frame posed it (the renderer poses rigs before the
/// scripts run, as WE's object loop does), for this frame's scripts.
struct SceneScriptRigFeedback: Equatable {
    struct Layer: Equatable {
        var key: Int
        var name: String
        var clip: Int
        var time: Float
        var frame: Float
        var flags: SceneTimelineClock.Flags
        var rate: Float
        var blend: Float
        var visible: Bool
        var additive: Bool
    }

    var layers: [Layer] = []
    /// Each bone's local matrix.
    var locals: [simd_float4x4] = []
    /// Each bone's world matrix: the object's world times its model-space matrix (0x14020f1d0).
    var worlds: [simd_float4x4] = []
    /// Layers whose clip reached its end since the last feedback (`addEndedCallback`).
    var ended: [Int] = []
    /// The first mesh's blend-shape weights (`getBlendShapeWeight`).
    var blendShapeWeights: [Float] = []
    /// Clip events the layers crossed since the last feedback, in the order they were crossed:
    /// each is an `animationEvent` for the object's scripts (`SceneScriptEvent.rigAnimation`).
    var events: [SceneAnimationLayerUpdate.Event] = []
}
