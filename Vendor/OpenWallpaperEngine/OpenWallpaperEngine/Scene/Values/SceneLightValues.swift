import simd

/// WE's values for a light field the object doesn't author: the light constructor in
/// `wallpaper64.exe` (0x140190457…0x1401904e4), matched to the fields through the property table
/// at 0x14025da80 (docs/lighting-plan.md §1.1). A missing key leaves the constructor's value.
enum SceneLightDefaults {
    /// Colour and intensity are zeroed (0x140190460, 0x14019047f): a light that authors neither is black.
    static let color = SIMD3<Float>(repeating: 0)
    static let intensity: Float = 0
    static let radius: Float = 1
    static let exponent: Float = 2
    /// Half-angles in degrees.
    static let innerCone: Float = 20
    static let outerCone: Float = 30
    /// A tube's end B in the light's local space; end A is the light's origin.
    static let controlPoint = SIMD3<Float>(2, 0, 0)
    static let density: Float = 2
    static let volumetricsExponent: Float = 1
    static let cascadeDistances = SIMD3<Float>(3, 10, 100)
    static let lightSourceSize: Float = 0
    /// The texture of a `usecookie` light that names none, or an empty one (0x14025d1b7).
    static let cookie = "cookie/flashlight1"
}

/// A light's fields resolved against the user properties, with WE's defaults for the ones it
/// doesn't author. Its transform, parent and visibility are its scene object's.
struct SceneLight: Equatable {
    var kind: WELightKind
    var color = SceneLightDefaults.color
    var intensity = SceneLightDefaults.intensity
    var radius = SceneLightDefaults.radius
    var exponent = SceneLightDefaults.exponent
    var innerCone = SceneLightDefaults.innerCone
    var outerCone = SceneLightDefaults.outerCone
    var controlPoint = SceneLightDefaults.controlPoint
    /// Bits 0, 1 and 2 of the light's flags (0x2c4), all off by default.
    var castShadow = false
    var useCookie = false
    var castVolumetrics = false
    var density = SceneLightDefaults.density
    var volumetricsExponent = SceneLightDefaults.volumetricsExponent
    /// `cascadedistance0/1/2`: a directional light's shadow cascades.
    var cascadeDistances = SceneLightDefaults.cascadeDistances
    var lightSourceSize = SceneLightDefaults.lightSourceSize
    /// The cookie texture a `usecookie` light loads (its `cookie`, else `SceneLightDefaults.cookie`);
    /// nil without `usecookie`.
    var cookie: String?

    init(kind: WELightKind) {
        self.kind = kind
    }

    init(_ light: WESceneLight, in context: SceneValueContext) {
        self.init(kind: light.kind)
        func value(_ field: SceneLightValueField) -> ShaderValue? {
            // User bindings are resolved in the document (`UserPropertyBindingTable`).
            light.values[field]?.literalString.flatMap(ShaderValue.init(string:))
        }
        func float(_ field: SceneLightValueField, _ fallback: Float) -> Float { value(field)?.float ?? fallback }
        func flag(_ field: SceneLightValueField) -> Bool { (value(field)?.float ?? 0) != 0 }
        // A scalar property bound to the colour (a slider) sets every channel, as on any object.
        color = value(.color).map { $0.components.count == 1 ? SIMD3(repeating: $0.float) : $0.vec3 }
            ?? SceneLightDefaults.color
        intensity = float(.intensity, SceneLightDefaults.intensity)
        radius = float(.radius, SceneLightDefaults.radius)
        exponent = float(.exponent, SceneLightDefaults.exponent)
        innerCone = float(.innercone, SceneLightDefaults.innerCone)
        outerCone = float(.outercone, SceneLightDefaults.outerCone)
        controlPoint = value(.controlpoint)?.vec3 ?? SceneLightDefaults.controlPoint
        castShadow = flag(.castshadow)
        useCookie = flag(.usecookie)
        castVolumetrics = flag(.castvolumetrics)
        density = float(.density, SceneLightDefaults.density)
        volumetricsExponent = float(.volumetricsexponent, SceneLightDefaults.volumetricsExponent)
        cascadeDistances = SIMD3(float(.cascadedistance0, SceneLightDefaults.cascadeDistances.x),
                                 float(.cascadedistance1, SceneLightDefaults.cascadeDistances.y),
                                 float(.cascadedistance2, SceneLightDefaults.cascadeDistances.z))
        lightSourceSize = float(.lightsourcesize, SceneLightDefaults.lightSourceSize)
        if useCookie { cookie = light.cookie.flatMap { $0.isEmpty ? nil : $0 } ?? SceneLightDefaults.cookie }
    }
}
