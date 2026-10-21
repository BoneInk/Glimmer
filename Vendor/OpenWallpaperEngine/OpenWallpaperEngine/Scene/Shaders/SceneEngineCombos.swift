import Foundation

/// The combos WE's engine sets on the materials it compiles, from the scene and the user's
/// settings rather than the material (`wallpaper64.exe` 0x1401a5c40; docs/lighting-plan.md §2.2):
/// `LIGHTS_*`, `LIGHTS_SHADOW_MAPPING*` and `LIGHTS_COOKIE` from the light budget when the
/// material's `LIGHTING` is on, `HDR`, `SCENE_ORTHO` and the like on every material.
///
/// One value per content build, handed to every material plan builder (image, effect and particle
/// materials), which lays `combos(for:)` over the material's resolved combos. Each combo arrives
/// with the feature that provides its inputs: the lighting ones are in, `HDR` is not yet.
struct SceneEngineCombos: Equatable {
    /// The scene draws in HDR (`general.bloom` and `hdr`, and post-processing "ultra" or above).
    var hdr = false
    /// The scene's projection is orthographic.
    var sceneOrtho = true
    /// `general.lightconfig` as the user's shadows setting leaves it; nil when the scene has none.
    var lightBudget: WELightConfig?
    /// The user's shadows setting (0 disabled … 4 ultra), for `LIGHTS_SHADOW_MAPPING_QUALITY`.
    var shadowQuality = 0
    /// `general.fogdistance` and `fogheight` (`SceneEngineCombos+Fog.swift`).
    var fogDistance = false
    var fogHeight = false

    init(hdr: Bool = false, sceneOrtho: Bool = true, lightBudget: WELightConfig? = nil, shadowQuality: Int = 0,
         fogDistance: Bool = false, fogHeight: Bool = false) {
        self.hdr = hdr
        self.sceneOrtho = sceneOrtho
        self.lightBudget = lightBudget
        self.shadowQuality = shadowQuality
        self.fogDistance = fogDistance
        self.fogHeight = fogHeight
    }

    /// The engine combos for a scene: HDR only when `bloom` and `hdr` are both on and the
    /// post-processing setting is "ultra" or "displayhdr" (0x14010e612…0x14010e6da); the light
    /// budget folded as the shadows setting requires (0x140187c39).
    init(bloom: SceneBloomSettings, lighting: SceneLightingSettings, orthographic: Bool, settings: SceneRenderSettings) {
        let shadows = settings.shadows.level
        self.init(hdr: bloom.enabled && bloom.hdr.enabled && settings.postProcessing.allowsHDR,
                  sceneOrtho: orthographic,
                  lightBudget: shadows == 0 ? lighting.lightConfig?.withShadowsDisabled : lighting.lightConfig,
                  shadowQuality: shadows, fogDistance: lighting.fog.distance, fogHeight: lighting.fog.height)
    }

    /// The combos to lay over a material whose own combos resolved to `material` (its `LIGHTING`
    /// decides the light combos): the lighting ones (`SceneEngineCombos+Lighting.swift`), the
    /// HDR ones (`SceneEngineCombos+HDR.swift`), the fog ones (`SceneEngineCombos+Fog.swift`) and
    /// `REVERSEDEPTH`.
    func combos(for material: [String: Int]) -> [String: Int] {
        var combos = lightingCombos(for: material).merging(hdrCombos(for: material)) { _, hdr in hdr }
            .merging(fogCombos(for: material)) { _, fog in fog }
        // WE's depth is reversed everywhere (docs/models-plan.md §2.4), and 0x1401a5c40 says so to
        // every material. Only shaders that name it see it (`effectiveCombos`).
        combos["REVERSEDEPTH"] = 1
        return combos
    }

    /// `material` with the engine's combos laid over it.
    func applied(to material: [String: Int]) -> [String: Int] {
        material.merging(combos(for: material)) { _, engine in engine }
    }
}
