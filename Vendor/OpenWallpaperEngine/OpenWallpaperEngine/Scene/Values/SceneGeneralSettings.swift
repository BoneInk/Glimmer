import simd

extension WESceneGeneral {
    /// A bindable `general` field as authored, its user binding already resolved by
    /// `UserPropertyBindingTable`; nil when not authored.
    func value(_ field: SceneGeneralValueField, in context: SceneValueContext) -> ShaderValue? {
        values[field]?.literalString.flatMap(ShaderValue.init(string:))
    }

    /// `general.clearcolor`: what WE clears the scene target to each frame, as authored (no
    /// colour-space conversion) with alpha 1 (0x14018031f…0x140180351).
    func clearColor(in context: SceneValueContext) -> SIMD3<Float> {
        value(.clearcolor, in: context)?.vec3 ?? SceneGeneralDefaults.clearColor
    }

    /// `general.clearenabled`: whether WE clears the scene target (colour and depth) before each
    /// frame's scene pass (0x140183588 tests scene flag 0x20, 0x14019b920 sets it). On unless
    /// authored false: the constructor's flags (0x26) hold it. Off, each frame draws over the last.
    func clearEnabled(in context: SceneValueContext) -> Bool {
        (value(.clearenabled, in: context)?.float ?? 1) != 0
    }
}

/// WE's defaults for the `general` block when a scene doesn't author a field: the scene
/// settings constructor in `wallpaper64.exe` (0x140186f84…0x1401870e3), matched to the field
/// names through WE's property table (0x14019a…0x14019b2a0).
enum SceneGeneralDefaults {
    static let bloomStrength: Float = 2
    static let bloomThreshold: Float = 0.65
    static let bloomTint = SIMD3<Float>(repeating: 1)
    static let cameraShakeSpeed: Float = 3
    static let cameraShakeAmplitude: Float = 0.5
    static let cameraShakeRoughness: Float = 1
    static let cameraParallaxAmount: Float = 0.5
    static let cameraParallaxDelay: Float = 0.1
    static let cameraParallaxMouseInfluence: Float = 0.5
    /// HDR bloom (0x1401870c2…0x1401870ee); `bloomhdriterations` is an int.
    static let bloomHDRStrength: Float = 2
    static let bloomHDRThreshold: Float = 1
    static let bloomHDRFeather: Float = 0.1
    static let bloomHDRScatter: Float = 1.619
    static let bloomHDRIterations = 8
    /// The constructor zeroes both colours (0x140186f68…0x140186f7d). Every library scene authors
    /// them (mostly 0.3 grey), so the zero is rarely seen.
    static let ambientColor = SIMD3<Float>(repeating: 0)
    static let skylightColor = SIMD3<Float>(repeating: 0)
    /// Zeroed by the constructor too (0x140186f61…0x140186f6f).
    static let clearColor = SIMD3<Float>(repeating: 0)
}

/// `general.hdr` and `bloomhdr*`, resolved against the user properties. WE turns HDR on at load
/// only when `bloom` and `hdr` are both true and the user's post-processing setting allows it
/// (docs/lighting-plan.md §2.6).
struct SceneHDRBloomSettings: Equatable {
    var enabled = false
    var strength = SceneGeneralDefaults.bloomHDRStrength
    var threshold = SceneGeneralDefaults.bloomHDRThreshold
    var feather = SceneGeneralDefaults.bloomHDRFeather
    var scatter = SceneGeneralDefaults.bloomHDRScatter
    var iterations = SceneGeneralDefaults.bloomHDRIterations

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        enabled = float(.hdr, 0) != 0
        strength = float(.bloomhdrstrength, SceneGeneralDefaults.bloomHDRStrength)
        threshold = float(.bloomhdrthreshold, SceneGeneralDefaults.bloomHDRThreshold)
        feather = float(.bloomhdrfeather, SceneGeneralDefaults.bloomHDRFeather)
        scatter = float(.bloomhdrscatter, SceneGeneralDefaults.bloomHDRScatter)
        let authoredIterations = float(.bloomhdriterations, Float(SceneGeneralDefaults.bloomHDRIterations))
        iterations = authoredIterations.isFinite ? Int(authoredIterations) : SceneGeneralDefaults.bloomHDRIterations
    }
}

/// `general.ambientcolor`, `skylightcolor`, `lightconfig` and the fog, resolved against the user
/// properties: the scene-wide lighting inputs (docs/lighting-plan.md §1.2, §2.2, §2.9).
struct SceneLightingSettings: Equatable {
    var ambient = SceneGeneralDefaults.ambientColor
    var skylight = SceneGeneralDefaults.skylightColor
    /// The light budget; nil packs no new-style light.
    var lightConfig: WELightConfig?
    var fog = SceneFogSettings()

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        ambient = general.value(.ambientcolor, in: context)?.vec3 ?? SceneGeneralDefaults.ambientColor
        skylight = general.value(.skylightcolor, in: context)?.vec3 ?? SceneGeneralDefaults.skylightColor
        lightConfig = general.lightconfig
        fog = SceneFogSettings(general, in: context)
    }
}

extension SceneBloomSettings {
    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        let tint = general.bloomtint.map { $0.parseVector3() }
            .map { SIMD3<Float>(Float($0.0), Float($0.1), Float($0.2)) } ?? SceneGeneralDefaults.bloomTint
        // A scene without `bloom` blooms: the constructor's flags (0x26, 0x140186d1f) hold bit 2,
        // which `bloom` sets and clears (0x14019b4e0).
        self.init(enabled: (general.value(.bloom, in: context)?.float ?? 1) != 0,
                  strength: general.value(.bloomstrength, in: context)?.float ?? SceneGeneralDefaults.bloomStrength,
                  threshold: general.value(.bloomthreshold, in: context)?.float ?? SceneGeneralDefaults.bloomThreshold,
                  tint: tint, hdr: SceneHDRBloomSettings(general, in: context))
    }
}

/// `general.camerashake*` and `general.cameraparallax*`, resolved against the user properties.
struct SceneCameraEffects: Equatable {
    var shake = false
    var shakeAmplitude = SceneGeneralDefaults.cameraShakeAmplitude
    var shakeSpeed = SceneGeneralDefaults.cameraShakeSpeed
    var shakeRoughness = SceneGeneralDefaults.cameraShakeRoughness
    var parallax = false
    var parallaxAmount = SceneGeneralDefaults.cameraParallaxAmount
    var parallaxDelay = SceneGeneralDefaults.cameraParallaxDelay
    var parallaxMouseInfluence = SceneGeneralDefaults.cameraParallaxMouseInfluence
    /// False for a perspective scene (`general.projection`, docs/models-plan.md §2.1). WE displaces
    /// objects for parallax only in an orthographic scene, and scales its shake by the projection
    /// height.
    var orthographic = true

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        shake = float(.camerashake, 0) != 0
        shakeAmplitude = float(.camerashakeamplitude, SceneGeneralDefaults.cameraShakeAmplitude)
        shakeSpeed = float(.camerashakespeed, SceneGeneralDefaults.cameraShakeSpeed)
        shakeRoughness = float(.camerashakeroughness, SceneGeneralDefaults.cameraShakeRoughness)
        parallax = float(.cameraparallax, 0) != 0
        parallaxAmount = float(.cameraparallaxamount, SceneGeneralDefaults.cameraParallaxAmount)
        parallaxDelay = float(.cameraparallaxdelay, SceneGeneralDefaults.cameraParallaxDelay)
        parallaxMouseInfluence = float(.cameraparallaxmouseinfluence, SceneGeneralDefaults.cameraParallaxMouseInfluence)
        orthographic = !general.projection.isPerspective
    }
}

/// `general.gravitydirection`, `gravitystrength`, `windenabled`, `winddirection` and
/// `windstrength`, resolved against the user properties: the scene options' Physics section
/// (`ui_editor_scene_options_physics`). WE registers them in its `general` property table
/// (0x14019b2b7…0x14019b4b6: the direction at +0x3e4, the strength at +0x3f0, wind on as bit
/// 0x10000 of the flags at +0xe0, its direction at +0x3f4 and strength at +0x400) and the
/// constructor sets the defaults below (0x140187006…0x140187104; the flags' 0x26 leaves wind off).
///
/// In WE 2.8.42 only Puppet Warp's rope simulation reads them: the scene's physics interface
/// (`general` + 0x50, vtable 0x14048ea08) answers `gravity` (+0x30) and `wind` (+0x38), and the
/// only caller of either is the puppet update's kinematic-chain step (0x1402036c4…0x140203744,
/// docs/models-plan.md §2.14). Spring and rigid bones keep their own `gd`/`m` gravity, and model
/// bones neither, so the app applies neither there.
struct ScenePhysicsSettings: Equatable {
    var gravityDirection = SceneGeneralDefaults.gravityDirection
    var gravityStrength = SceneGeneralDefaults.gravityStrength
    var windEnabled = false
    var windDirection = SceneGeneralDefaults.windDirection
    var windStrength = SceneGeneralDefaults.windStrength

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        gravityDirection = general.value(.gravitydirection, in: context)?.vec3 ?? SceneGeneralDefaults.gravityDirection
        gravityStrength = float(.gravitystrength, SceneGeneralDefaults.gravityStrength)
        windEnabled = float(.windenabled, 0) != 0
        windDirection = general.value(.winddirection, in: context)?.vec3 ?? SceneGeneralDefaults.windDirection
        windStrength = float(.windstrength, SceneGeneralDefaults.windStrength)
    }

    /// The interface's `gravity` (0x1401988e0): the direction times the strength, unnormalised.
    var gravity: SIMD3<Float> { gravityDirection * gravityStrength }
}

extension SceneGeneralDefaults {
    /// The constructor's (0, −1, 0) (0x140187006…0x14018701c).
    static let gravityDirection = SIMD3<Float>(0, -1, 0)
    static let gravityStrength: Float = 1
    /// 0.707 0.707 0 (0x140187023…0x14018702e).
    static let windDirection = SIMD3<Float>(0.707, 0.707, 0)
    static let windStrength: Float = 1
}
