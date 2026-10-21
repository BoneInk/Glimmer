import simd

/// `general.fog*`, resolved against the user properties: WE's distance and height fog
/// (`wallpaper64.exe`; docs/lighting-plan.md §2.9).
///
/// - `fogdistance` and `fogheight` are flags (scene +0xe0 bits 0x4000 and 0x8000). Each sets a
///   render flag (bits 23 and 24, 0x14018655a…0x1401865ad) under which the engine gives every
///   material whose `FOG` combo is on `FOG_DIST` or `FOG_HEIGHT` (0x1401a64ae…0x1401a666a).
/// - The shaders read `g_FogDistanceColor`/`g_FogDistanceParams` and `g_FogHeightColor`/
///   `g_FogHeightParams` (`common_fog.h`), which the scene writes as (start, end − start,
///   start density, end density − start density) (0x140186440…0x140186552).
struct SceneFogSettings: Equatable {
    var distance = false
    var height = false
    var distanceColor = SceneFogDefaults.color
    var heightColor = SceneFogDefaults.color
    var distanceStart = SceneFogDefaults.distanceStart
    var distanceEnd = SceneFogDefaults.distanceEnd
    var distanceStartDensity = SceneFogDefaults.startDensity
    var distanceEndDensity = SceneFogDefaults.endDensity
    var heightStart = SceneFogDefaults.heightStart
    var heightEnd = SceneFogDefaults.heightEnd
    var heightStartDensity = SceneFogDefaults.startDensity
    var heightEndDensity = SceneFogDefaults.endDensity

    init() {}

    init(_ general: WESceneGeneral, in context: SceneValueContext) {
        func float(_ field: SceneGeneralValueField, _ fallback: Float) -> Float {
            general.value(field, in: context)?.float ?? fallback
        }
        distance = float(.fogdistance, 0) != 0
        height = float(.fogheight, 0) != 0
        distanceColor = general.value(.fogdistancecolor, in: context)?.vec3 ?? SceneFogDefaults.color
        heightColor = general.value(.fogheightcolor, in: context)?.vec3 ?? SceneFogDefaults.color
        distanceStart = float(.fogdistancestart, SceneFogDefaults.distanceStart)
        distanceEnd = float(.fogdistanceend, SceneFogDefaults.distanceEnd)
        distanceStartDensity = float(.fogdistancestartdensity, SceneFogDefaults.startDensity)
        distanceEndDensity = float(.fogdistanceenddensity, SceneFogDefaults.endDensity)
        heightStart = float(.fogheightstart, SceneFogDefaults.heightStart)
        heightEnd = float(.fogheightend, SceneFogDefaults.heightEnd)
        heightStartDensity = float(.fogheightstartdensity, SceneFogDefaults.startDensity)
        heightEndDensity = float(.fogheightenddensity, SceneFogDefaults.endDensity)
    }

    /// `g_FogDistanceParams` (0x140186490…0x1401864e8).
    var distanceParams: SIMD4<Float> {
        SIMD4(distanceStart, distanceEnd - distanceStart, distanceStartDensity, distanceEndDensity - distanceStartDensity)
    }

    /// `g_FogHeightParams` (0x1401864f7…0x140186552).
    var heightParams: SIMD4<Float> {
        SIMD4(heightStart, heightEnd - heightStart, heightStartDensity, heightEndDensity - heightStartDensity)
    }
}

/// The scene constructor's fog values (0x140186fd4…0x1401870a1): black, distance 1…5, height
/// 1…−3, density 0…1.
enum SceneFogDefaults {
    static let color = SIMD3<Float>(repeating: 0)
    static let distanceStart: Float = 1
    static let distanceEnd: Float = 5
    static let heightStart: Float = 1
    static let heightEnd: Float = -3
    static let startDensity: Float = 0
    static let endDensity: Float = 1
}
