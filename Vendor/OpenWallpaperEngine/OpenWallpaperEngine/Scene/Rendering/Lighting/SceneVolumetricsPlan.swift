import Foundation

/// One of WE's volumetrics passes, resolved at load: a `materials/util` material's first pass,
/// its shader translated for the combos WE sets.
struct SceneVolumetricsPass {
    let material: String
    let variant: TranslatedShaderVariant
    let variantKey: String
    /// The material's `blending`, `cullmode` and `depthtest`.
    let blending: String
    let cullMode: String
    let depthTest: Bool
}

/// WE's volumetric lights for one content build (`wallpaper64.exe` 0x140196ce0 and 0x140198d00;
/// docs/lighting-plan.md §2.8), planned like the bloom chain: WE's own util materials through the
/// translator.
///
/// - Each light that casts volumetrics gets `volumetrics_back`, and `volumetrics_front` and
///   `volumetrics_fullscreen` compiled with WE's combos (0x140198124…0x140198489): `COOKIE` for a
///   cookie light, `SHADOW` for a shadow caster while shadows are on, `QUALITY` the volumetrics
///   setting, and a point light's `POINTLIGHT` and `LIGHTS_SHADOW_MAPPING_QUALITY`.
/// - The scene gets `volumetrics_combine`, and below quality 3 `volumetrics_blur_h`/`_v`
///   (0x140196eea…0x140196f52).
///
/// There is no plan while the setting is disabled or no light casts volumetrics.
struct SceneVolumetricsPlan {
    struct Light {
        /// The light's scene object.
        let id: String
        var light: SceneLight
        let back: SceneVolumetricsPass
        let front: SceneVolumetricsPass
        let fullscreen: SceneVolumetricsPass
        /// The front passes' `g_Texture2`: the light's own cookie (0x140198815), not the scene's
        /// `_alias_lightCookie`.
        let cookie: (key: String, source: SceneMetalTextureSource)?
    }

    /// The `volumetrics` setting the passes were compiled for, 1 (low) … 4 (ultra).
    let quality: Int
    let lights: [Light]
    /// Lights that cast volumetrics but aren't drawn, with why (logged once at load).
    let skipped: [(id: String, reason: String)]
    let blurH: SceneVolumetricsPass?
    let blurV: SceneVolumetricsPass?
    let combine: SceneVolumetricsPass

    /// WE blurs the light buffer below quality 3, and renders it at 1/8 of the frame there, 1/4
    /// from quality 3 up (0x140196d79…0x140196d88).
    static func blurs(quality: Int) -> Bool { quality < 3 }
    static func divisor(quality: Int) -> Int { quality >= 3 ? 4 : 8 }

    static let backMaterial = "materials/util/volumetrics_back.json"
    static let frontMaterial = "materials/util/volumetrics_front.json"
    static let fullscreenMaterial = "materials/util/volumetrics_fullscreen.json"
    static let blurHMaterial = "materials/util/volumetrics_blur_h.json"
    static let blurVMaterial = "materials/util/volumetrics_blur_v.json"
    static let combineMaterial = "materials/util/volumetrics_combine.json"

    enum BuildError: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String, Error)

        var description: String {
            switch self {
            case .missing(let path): return "missing \(path)"
            case .invalid(let path, let error): return "\(path): \(error)"
            }
        }
    }

    /// The front passes' combos for `light` (0x14019817e…0x140198440).
    static func combos(for light: SceneLight, quality: Int, shadowQuality: Int) -> [String: Int] {
        var combos = ["QUALITY": quality]
        if light.useCookie { combos["COOKIE"] = 1 }
        if castsShadow(light, shadowQuality: shadowQuality) { combos["SHADOW"] = 1 }
        if light.kind == .point {
            combos["POINTLIGHT"] = 1
            combos["LIGHTS_SHADOW_MAPPING_QUALITY"] = shadowQuality
        }
        return combos
    }

    /// Why WE's volumetrics can't draw `light` here yet, or nil.
    static func unsupported(_ light: SceneLight, shadowQuality: Int) -> String? {
        guard light.kind == .point || light.kind == .spot else {
            return "a \(light.kind) light's volume isn't a point's or a spot's [?]"
        }
        return nil
    }

    /// The light's volume reads its shadow map (`SHADOW`): it casts shadows while the shadows
    /// setting is on.
    static func castsShadow(_ light: SceneLight, shadowQuality: Int) -> Bool {
        light.castShadow && shadowQuality > 0
    }

    /// Plans `lights` with `builder`'s translator, files and engine combos; nil when the setting
    /// is disabled or no light casts volumetrics.
    static func build(lights: [SceneLightObject], settings: SceneRenderSettings,
                      builder: SceneEffectPlanBuilder) throws -> SceneVolumetricsPlan? {
        let quality = settings.volumetrics.level
        let casting = lights.filter(\.light.castVolumetrics)
        guard quality > 0, !casting.isEmpty else { return nil }
        let shadowQuality = settings.shadows.level
        let resolver = Resolver(builder: builder)
        var planned: [Light] = []
        var skipped: [(id: String, reason: String)] = []
        for object in casting {
            if let reason = unsupported(object.light, shadowQuality: shadowQuality) {
                skipped.append((object.id, reason))
                continue
            }
            let combos = Self.combos(for: object.light, quality: quality, shadowQuality: shadowQuality)
            var cookie: (key: String, source: SceneMetalTextureSource)?
            if let name = object.light.cookie {
                guard let found = Self.cookie(named: name, builder: builder) else {
                    skipped.append((object.id, "its cookie \(name) and WE's default \(SceneLightDefaults.cookie) are missing"))
                    continue
                }
                cookie = found
            }
            planned.append(Light(id: object.id, light: object.light,
                                 back: try resolver.pass(backMaterial),
                                 front: try resolver.pass(frontMaterial, combos: combos),
                                 fullscreen: try resolver.pass(fullscreenMaterial, combos: combos),
                                 cookie: cookie))
        }
        let blurs = Self.blurs(quality: quality)
        return SceneVolumetricsPlan(quality: quality, lights: planned, skipped: skipped,
                                    blurH: blurs ? try resolver.pass(blurHMaterial) : nil,
                                    blurV: blurs ? try resolver.pass(blurVMaterial) : nil,
                                    combine: try resolver.pass(combineMaterial))
    }

    /// A cookie light's texture: the one it names, else WE's default (0x14025d19f…0x14025d1cd
    /// loads `cookie/flashlight1` when the named one didn't load); nil when neither loads. WE
    /// would draw that light with no texture bound, which a `COOKIE` pass multiplies to nothing,
    /// so the light is skipped, not the whole plan.
    static func cookie(named name: String,
                       builder: SceneEffectPlanBuilder) -> (key: String, source: SceneMetalTextureSource)? {
        for candidate in [name, SceneLightDefaults.cookie] {
            if let source = builder.loadTexture(candidate, frontMaterial) { return ("\(frontMaterial)|\(candidate)", source) }
        }
        return nil
    }

    /// Reads WE's util materials and translates their shaders.
    private struct Resolver {
        let builder: SceneEffectPlanBuilder

        func pass(_ path: String, combos: [String: Int] = [:]) throws -> SceneVolumetricsPass {
            guard let data = builder.readFile(path) else { throw BuildError.missing(path) }
            let document: MaterialDocument
            do {
                document = try decodeTolerant(MaterialDocument.self, from: data)
            } catch {
                throw BuildError.invalid(path, error)
            }
            guard let pass = document.passes.first else { throw BuildError.missing("\(path) passes") }
            let loader = ShaderSourceLoader(readFile: builder.readFile)
            let vertex = try loader.load(pass.shader, stage: .vertex)
            let fragment = try loader.load(pass.shader, stage: .fragment)
            let resolved = builder.sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: [pass.combos, combos], boundTextureSlots: [0]))
            let variant = try builder.translator.variant(vertex: vertex, fragment: fragment, combos: resolved)
            return SceneVolumetricsPass(
                material: path, variant: variant,
                variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: resolved),
                blending: pass.blending ?? "normal", cullMode: pass.cullmode ?? "normal",
                depthTest: pass.depthtest != "disabled")
        }
    }
}
