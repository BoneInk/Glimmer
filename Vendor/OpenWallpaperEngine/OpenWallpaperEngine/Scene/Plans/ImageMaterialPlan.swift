import Foundation

/// An image layer's own material (`genericimage`, `genericimage2/3/4` or a Workshop shader),
/// resolved at load like pass 0 of an effect: the variant, its textures, combos and constants.
///
/// The renderer draws the layer with it: `g_Texture0` is the layer's image (after its effects),
/// and the layer's live transform, colour, alpha and brightness are its built-ins. A final class
/// so the renderer can key per-plan state on its identity.
final class ImageMaterialPlan {
    /// The material JSON, for logging.
    let materialPath: String
    /// `variant`, textures (slot 0 is `.current`, the layer image), constants and blending.
    let pass: SceneEffectPassPlan
    /// WE's prelighting pass (docs/lighting-plan.md §2.3), for a lit or reflective layer with
    /// effects: the material with its `LIGHTING`/`REFLECTION` and `PRELIGHTING` = 1, which draws
    /// the layer image, lit where the layer is, into the texture its effects start from. `pass`
    /// then has both combos off. nil for every other layer.
    let prelighting: SceneEffectPassPlan?
    /// The shader reads its UVs through `g_Texture0Rotation/Translation` (`SPRITESHEET`), so the
    /// quad carries plain 0...1 texture coordinates.
    let usesSpriteSheetUniforms: Bool
    /// Material-authored factors of the uniforms the layer's live values drive (`g_Brightness`,
    /// `g_UserAlpha`); the live value is multiplied by them.
    let liveFactors: [String: Float]
    /// Texture slots sampled with clamp-to-edge (the `.tex` ClampUVs flag, or the object's
    /// `clampuvs` for the layer image); every other slot repeats, as in WE.
    let clampedSlots: Set<Int>
    /// The first pass's `cullmode` as authored (nil: WE's default, back faces culled). Only a
    /// puppet's mesh has faces to cull; a layer's quad is drawn whole.
    let cullmode: String?
    /// The first pass's `depthtest`, `depthwrite` and `cullmode` (docs/models-plan.md §2.4): what
    /// the layer's quad draws with where the scene pass has depth.
    var raster = SceneRasterState.engineDefault
    /// The first pass's `alphawriting`: false when the material turns it off (Puppet Warp's
    /// "Alpha writing" option for texture channels), so the draw leaves the target's alpha [I].
    var writesAlpha = true

    init(materialPath: String, pass: SceneEffectPassPlan, prelighting: SceneEffectPassPlan? = nil, usesSpriteSheetUniforms: Bool,
         liveFactors: [String: Float], clampedSlots: Set<Int> = [0], cullmode: String? = nil) {
        self.materialPath = materialPath
        self.pass = pass
        self.prelighting = prelighting
        self.usesSpriteSheetUniforms = usesSpriteSheetUniforms
        self.liveFactors = liveFactors
        self.clampedSlots = clampedSlots
        self.cullmode = cullmode
    }

    /// WE draws the mesh two-sided when the material says `nocull` (0x1402071b5); anything else
    /// culls back faces.
    var cullsBackFaces: Bool { cullmode?.lowercased() != "nocull" }

    var readsSceneSnapshot: Bool { pass.readsSceneSnapshot }

    /// Uniforms that follow the layer's live colour, alpha and brightness rather than a constant.
    static let liveUniforms: Set<String> = ["g_Brightness", "g_UserAlpha", "g_Alpha", "g_Color", "g_Color4"]
}

/// The combos WE lays over a Puppet Warp image's material for its mesh (0x140207100, and the same
/// list at 0x14020a5d2 for the in-scene copy; docs/models-plan.md §2.13): `SKINNING` always,
/// `BONECOUNT` the skeleton's exact bone count (not rounded, unlike a model's), `SKINNING_ALPHA`
/// with mesh flag 0x4 (which WE's editor sets once a clip keys a bone's Opacity, capture 509 F),
/// `MORPHING` when the mesh carries `a_PositionVec4` (w is the morph index)
/// and `MORPHING_MODIFIERS` when it also has flag 0x2000. WE reads them from the first mesh.
struct ImagePuppetCombos: Equatable {
    var boneCount: Int
    var skinningAlpha: Bool
    var morphing: Bool
    var morphingModifiers: Bool

    init(boneCount: Int, skinningAlpha: Bool = false, morphing: Bool = false, morphingModifiers: Bool = false) {
        self.boneCount = boneCount
        self.skinningAlpha = skinningAlpha
        self.morphing = morphing
        self.morphingModifiers = morphingModifiers
    }

    init(mesh: MDLMesh, boneCount: Int) {
        let morphing = mesh.format.contains(.positionVec4)
        self.init(boneCount: boneCount, skinningAlpha: mesh.usesSkinningAlpha, morphing: morphing,
                  morphingModifiers: morphing && mesh.flags & 0x2000 != 0)
    }

    var combos: [String: Int] {
        var combos = ["SKINNING": 1, "BONECOUNT": boneCount]
        if skinningAlpha { combos["SKINNING_ALPHA"] = 1 }
        if morphing { combos["MORPHING"] = 1 }
        if morphingModifiers { combos["MORPHING_MODIFIERS"] = 1 }
        return combos
    }

    /// `g_Texture5`, WE's "morph_<n>" texture of position deltas: the engine binds it, the
    /// material doesn't list it.
    static let morphSlot = 5
    /// `g_Texture8` of `CLIPPINGTARGET`: the clipping mask's coverage.
    static let clippingMaskSlot = 8
    /// `g_Texture1` of `clippingmaskimage4`: the mask's painted texture.
    static let clippingMaskTextureSlot = 1
}

enum ImageMaterialPlanError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, Error)
    /// The material needs an engine feature that doesn't exist yet; the layer draws natively.
    case unsupported(String)

    var description: String {
        switch self {
        case .missing(let path): return "missing \(path)"
        case .invalid(let path, let error): return "\(path): \(error)"
        case .unsupported(let reason): return "unsupported: \(reason)"
        }
    }
}

/// Builds an `ImageMaterialPlan` from a model's material.
struct ImageMaterialPlanBuilder {
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper, falling back to the WE assets.
    let readFile: (String) -> Data?
    /// Loads a texture by WE name relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?
    /// The combos WE's engine lays over every material of the scene (`SceneEngineCombos`).
    var sceneEngineCombos = SceneEngineCombos()
    /// The layer's blending in place of its material's first pass's (Scene Edit / Export's,
    /// `sceneObjectBlendingKey`); nil keeps the material's.
    var blending: WEMaterialBlending?

    /// nil when the material has no image to draw: no texture in slot 0 (solid layers' `flat`) or a
    /// render target there (composition layers), which keep their own paths.
    /// `colorBlendMode` is the object's WE blend mode (`BLENDMODE` combo), when authored; `clampUVs`
    /// is the object's `clampuvs`. `prelit` is set for a layer with effects, whose
    /// lighting and reflection WE applies in a pass before them (`ImageMaterialPlan.prelighting`).
    func build(materialPath: String, colorBlendMode: Int?, clampUVs: Bool? = nil, prelit: Bool = false) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: colorBlendMode, clampUVs: clampUVs, listsItsImage: true,
                  prelit: prelit)
    }

    /// A Puppet Warp image's mesh pass (docs/models-plan.md §2.13, §4.3 P1): the layer's own material
    /// with WE's puppet combos (`ImagePuppetCombos`), drawn into the image-sized albedo target that
    /// the layer's effects and its own draw then read (`ScenePuppetRenderer`). `LIGHTING` and
    /// `REFLECTION` are off and the object's blend mode isn't applied: the layer's own pass lights
    /// and blends that target, as WE's base material does for a layer with effects (0x140206fcb).
    /// `plan.pass` is the mesh pass; `plan.prelighting` is nil.
    func buildPuppetMesh(materialPath: String, puppet: ImagePuppetCombos) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: nil, clampUVs: nil, listsItsImage: true, prelit: false,
                  puppet: puppet)
    }

    /// The draw of a Puppet Warp rig's clipped parts (0x14020a978…0x14020aa5d): the mesh pass with
    /// `CLIPPINGUVS` and `CLIPPINGTARGET` = 1, whose `g_Texture8` is the mask's coverage
    /// (`_rt_FullAlphaMask`, bound by the renderer) sampled at the fragment's place in the target.
    /// Only `genericimage4` reads them; any other shader draws the parts unclipped, as WE does
    /// (the default `genericimage2` puppet of WE 2.8's captures 532 and 532c shows no clipping).
    func buildPuppetClipTarget(materialPath: String, puppet: ImagePuppetCombos) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: nil, clampUVs: nil, listsItsImage: true, prelit: false,
                  puppet: puppet, extraCombos: ["CLIPPINGUVS": 1, "CLIPPINGTARGET": 1],
                  engineSlots: [ImagePuppetCombos.clippingMaskSlot])
    }

    /// The material a Puppet Warp rig's clipping masks are drawn with (0x14020ab12…0x14020ad8f):
    /// `materials/util/clippingmaskimage4.json` with the puppet combos, and `ALPHATOCOVERAGE`
    /// when the layer's material blends that way. `g_Texture0` is the layer image; the renderer
    /// binds the mask's texture to `g_Texture1`.
    func buildPuppetClippingMask(puppet: ImagePuppetCombos, alphaToCoverage: Bool) throws -> ImageMaterialPlan? {
        try build(materialPath: Self.clippingMaskMaterial, colorBlendMode: nil, clampUVs: nil, listsItsImage: false,
                  prelit: false, puppet: puppet, extraCombos: alphaToCoverage ? ["ALPHATOCOVERAGE": 1] : [:],
                  engineSlots: [ImagePuppetCombos.clippingMaskTextureSlot])
    }

    static let clippingMaskMaterial = "materials/util/clippingmaskimage4.json"

    /// A puppet's texture-channel material (`puppettexturechannels`, the mesh with flag 0x2;
    /// 0x140209f28): the material as authored, every texture its own (`g_Texture0` the channel
    /// atlas, `g_Texture1` the base image), with `BLENDROWCOUNT` = the mesh's row count. WE
    /// creates it with that combo alone, and its draw runs without `DOUBLEBUFFERED` although
    /// `g_Texture1` is bound (WE 2.8.42's capture of the rope: the pixel shader has no discard).
    func buildPuppetTextureChannels(materialPath: String, blendRows: Int) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: nil, clampUVs: nil, listsItsImage: false, prelit: false,
                  extraCombos: ["BLENDROWCOUNT": blendRows, "DOUBLEBUFFERED": 0], imageIsAsset: true)
    }

    /// A text object's font material (`materials/fonts/basefont*.json`, WE's `font` shader). It
    /// lists no texture: `g_Texture0` is the rasterised text, a coverage mask the shader tints with
    /// `g_Color4` (the text's colour, brightness and alpha). Clamped, since it is exactly the text.
    func buildText(materialPath: String) throws -> ImageMaterialPlan? {
        try build(materialPath: materialPath, colorBlendMode: nil, clampUVs: true, listsItsImage: false, prelit: false)
    }

    /// The material WE composites a layer's own image with when its material can't blend
    /// (0x1401ebe37…0x1401ebe55): `effectpassthrough_4.json` (genericimage4) with `BLENDMODE` =
    /// `colorBlendMode` and `FOG_COMPUTED`. WE turns mode 31 into 0 and adds with the pass's
    /// blending; `ApplyBlending`'s 31 (A + B·opacity) is the same sum. For a solid layer, whose
    /// `flat` shader has no `BLENDMODE`: `g_Texture0` is the layer's filled image.
    func buildBlendComposite(colorBlendMode: Int) throws -> ImageMaterialPlan? {
        try build(materialPath: Self.blendCompositeMaterial, colorBlendMode: colorBlendMode, clampUVs: true,
                  listsItsImage: false, prelit: false, extraCombos: ["FOG_COMPUTED": 1])
    }

    static let blendCompositeMaterial = "materials/util/effectpassthrough_4.json"

    /// The combos WE's material pass loader sets from the pass's blending, whatever the object:
    /// `ALPHATOCOVERAGE` = 1 for alpha-to-coverage (blend byte 3, 0x140154bc1) and `ADDITIVE` = 1
    /// for additive (blend byte 2, 0x140154c5a). Only the lit shaders' fog reads `ADDITIVE`
    /// (`generic4`, `chroma4`, `fur4`, `foliage4`: the fog fades the alpha too).
    static func blendingCombos(blending: String?) -> [String: Int] {
        switch blending?.lowercased() {
        case "alphatocoverage": ["ALPHATOCOVERAGE": 1]
        case "additive": ["ADDITIVE": 1]
        default: [:]
        }
    }

    private func build(materialPath: String, colorBlendMode: Int?, clampUVs: Bool?,
                       listsItsImage: Bool, prelit: Bool, puppet: ImagePuppetCombos? = nil,
                       extraCombos: [String: Int] = [:], imageIsAsset: Bool = false,
                       engineSlots: Set<Int> = []) throws -> ImageMaterialPlan? {
        guard let data = readFile(materialPath) else { throw ImageMaterialPlanError.missing(materialPath) }
        let material: MaterialDocument
        do {
            material = try decodeTolerant(MaterialDocument.self, from: data)
        } catch {
            throw ImageMaterialPlanError.invalid(materialPath, error)
        }
        guard var materialPass = material.passes.first else { throw ImageMaterialPlanError.missing("\(materialPath) passes") }
        if let blending { materialPass.blending = blending.rawValue }
        let image = materialPass.textures.first ?? nil
        if listsItsImage, image == nil || image!.hasPrefix("_rt_") {
            // Such a layer keeps its own draw, which has no scene blend: say so rather than drop it quietly.
            if let colorBlendMode, colorBlendMode != 0 {
                throw ImageMaterialPlanError.unsupported("colorBlendMode \(colorBlendMode) on \(materialPass.shader), which draws no image")
            }
            return nil
        }

        let loader = ShaderSourceLoader(readFile: readFile, memo: translator.sources)
        let vertex = try loader.load(materialPass.shader, stage: .vertex)
        let fragment = try loader.load(materialPass.shader, stage: .fragment)

        var listed: [Int: SceneEffectTextureInput] = [:]
        var headers: [Int: Data] = [:]
        for (slot, name) in materialPass.textures.enumerated() where slot > 0 || imageIsAsset {
            guard let name else { continue }
            listed[slot] = try textureInput(named: name, materialPath: materialPath)
            if listed[slot] != nil, !name.hasPrefix("_rt_") { headers[slot] = textureHeader(name, materialPath: materialPath) }
        }
        let formats = Self.formatCombos(vertex.samplers + fragment.samplers,
                                        headers: formatHeaders(vertex.samplers + fragment.samplers, listed: headers,
                                                               materialPath: materialPath))
        // WE's material pass loader sets `ALPHATOCOVERAGE` and `ADDITIVE` from the pass's blending,
        // whatever the object (0x140154bc1, 0x140154c5a; as for models).
        let coverage = Self.blendingCombos(blending: materialPass.blending)
        let combos = { (overrides: [[String: Int]]) in
            sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
                vertex: vertex, fragment: fragment, overrides: [materialPass.combos, coverage, extraCombos] + overrides + [formats],
                boundTextureSlots: Set(listed.keys).union([0]).union(engineSlots),
                textureFlags: headers.compactMapValues { TEXHeader.texiWord(1, in: $0) }))
        }

        let uniforms = (vertex.uniforms + fragment.uniforms).filter { !$0.isSampler }
            .reduce(into: [ShaderUniformDeclaration]()) { result, uniform in
                if !result.contains(where: { $0.name == uniform.name }) { result.append(uniform) }
            }
        let resolved = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: materialPass.constantSources(uniforms: uniforms), instance: [:])
        // The layer's live values drive these; a static material value scales them.
        var liveFactors: [String: Float] = [:]
        for name in ["g_Brightness", "g_UserAlpha"] {
            if let value = resolved.staticValues[name] { liveFactors[name] = value.float }
        }
        let constants = ShaderConstantResolver.ResolvedConstants(
            staticValues: resolved.staticValues.filter { !ImageMaterialPlan.liveUniforms.contains($0.key) },
            dynamic: resolved.dynamic)

        // One variant of the material: nil when it doesn't draw the layer image (slot 0).
        func pass(_ combos: [String: Int], blending: String) throws -> SceneEffectPassPlan? {
            let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
            // A variant may declare samplers it never reads: `font` declares COLORFONT's colour
            // atlas (`g_Texture1`) in every variant, `genericimage4` its normal map and PBR mask
            // whenever `LIGHTING` or `REFLECTION` is on. SPIRV-Cross emits only the textures a stage
            // uses, and one it doesn't emit needs nothing bound.
            let msl = variant.vertexMSL + variant.fragmentMSL
            let sampled = Set(variant.textureSlots).filter { $0 == 0 || msl.contains("[[texture(\($0))]]") }
            guard sampled.contains(0) else { return nil }
            var inputs = listed.filter { sampled.contains($0.key) }
            for sampler in vertex.samplers + fragment.samplers {
                guard let slot = sampler.textureSlot, slot != 0, sampled.contains(slot), inputs[slot] == nil,
                      let name = sampler.defaultTexture else { continue }
                inputs[slot] = try textureInput(named: name, materialPath: materialPath)
            }
            if !imageIsAsset { inputs[0] = .current }
            // The puppet renderer binds the morph texture itself.
            let engineBound: Set<Int> = (puppet?.morphing == true ? Set([ImagePuppetCombos.morphSlot]) : Set<Int>()).union(engineSlots)
            if let unbound = sampled.subtracting(inputs.keys).subtracting(engineBound).min() {
                throw ImageMaterialPlanError.unsupported("g_Texture\(unbound) has no texture")
            }
            return SceneEffectPassPlan(command: .render,
                                       variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                       variant: variant, blending: blending, target: nil, textures: inputs, constants: constants)
        }

        var drawn = combos(colorBlendMode.map { [["BLENDMODE": $0]] } ?? [])
        var prelighting: SceneEffectPassPlan?
        if let puppet {
            drawn = combos([["LIGHTING": 0, "REFLECTION": 0], puppet.combos])
        } else if prelit, (drawn["LIGHTING"] ?? 0) != 0 || (drawn["REFLECTION"] ?? 0) != 0 {
            // WE's prelighting (0x140209540, docs/lighting-plan.md §2.3): the material, lit, with
            // `PRELIGHTING` (and `cullmode` nocull) draws the layer image into the buffer its effects
            // start from; the layer itself draws with both combos off. Neither takes the object's
            // blend mode into the buffer.
            prelighting = try pass(combos([["PRELIGHTING": 1]]), blending: "disabled")
            drawn = combos([["LIGHTING": 0, "REFLECTION": 0]] + (colorBlendMode.map { [["BLENDMODE": $0]] } ?? []))
        }
        guard let layerPass = try pass(drawn, blending: materialPass.blending ?? "normal") else { return nil }

        var clampedSlots = Set<Int>()
        if clampUVs == true || image.map({ textureClamps($0, materialPath: materialPath) }) ?? true { clampedSlots.insert(0) }
        for (slot, input) in layerPass.textures.merging(prelighting?.textures ?? [:], uniquingKeysWith: { a, _ in a }) {
            switch input {
            case .sceneSnapshot, .mipMappedFrameBuffer: clampedSlots.insert(slot)
            case .asset(let key, _):
                if textureClamps(String(key.dropFirst(materialPath.count + 1)), materialPath: materialPath) {
                    clampedSlots.insert(slot)
                }
            default: break
            }
        }
        let plan = ImageMaterialPlan(materialPath: materialPath, pass: layerPass, prelighting: prelighting,
                                     usesSpriteSheetUniforms: (layerPass.variant?.combos["SPRITESHEET"] ?? 0) != 0,
                                     liveFactors: liveFactors, clampedSlots: clampedSlots, cullmode: materialPass.cullmode)
        plan.raster = SceneRasterState(depthtest: materialPass.depthtest, depthwrite: materialPass.depthwrite,
                                       cullmode: materialPass.cullmode, blending: materialPass.blending)
        plan.writesAlpha = !["false", "disabled", "0"].contains(materialPass.alphawriting?.lowercased() ?? "")
        return plan
    }

    /// The `.tex` ClampUVs flag (TEXI flags bit 2) of texture `name`, looked up like the texture
    /// loader does. A texture that isn't a `.tex` (or can't be read) clamps.
    func textureClamps(_ name: String, materialPath: String) -> Bool {
        guard let data = textureHeader(name, materialPath: materialPath), let flags = TEXHeader.texiWord(1, in: data) else { return true }
        return flags & Self.texClampUVsFlag != 0
    }

    /// The `.tex` file of texture `name`, looked up like the texture loader does; nil when there is none.
    func textureHeader(_ name: String, materialPath: String) -> Data? {
        let directory = (materialPath as NSString).deletingLastPathComponent
        let root = directory.split(separator: "/").first.map(String.init) ?? "materials"
        for path in ["\(directory)/\(name).tex", "\(root)/\(name).tex", "materials/\(name).tex", "\(name).tex"] {
            if let data = readFile(path) { return data }
        }
        return nil
    }

    /// `TEX<n>FORMAT` for the samplers annotated `"formatcombo": true` with a texture header in
    /// `headers` (the texture listed in the slot, else the sampler's `default`; `formatHeaders`),
    /// as `SceneEffectPlanBuilder` sets it: WE sets it to the format of the texture that fills the
    /// slot, whatever it is (0x1401a6902…0x1401a69e4: the default texture loads first). Here
    /// `TEXImageFormat.formatComboValue`: `fur4` reads `TEX8FORMAT` outside an `#if`, so the name
    /// must exist for an RGBA texture too.
    static func formatCombos(_ samplers: [ShaderUniformDeclaration], headers: [Int: Data]) -> [String: Int] {
        var combos: [String: Int] = [:]
        for sampler in samplers where sampler.isFormatCombo {
            guard let slot = sampler.textureSlot, let header = headers[slot],
                  let format = TEXImageFormat(texData: header) else { continue }
            combos["TEX\(slot)FORMAT"] = format.formatComboValue
        }
        return combos
    }

    /// `listed` (texture headers by slot) plus, for each `"formatcombo"` sampler without one, its
    /// `default` texture's header: the texture that fills the slot (`formatCombos`). Slot 0 is
    /// the object's own image, never the default.
    func formatHeaders(_ samplers: [ShaderUniformDeclaration], listed: [Int: Data], materialPath: String) -> [Int: Data] {
        var headers = listed
        for sampler in samplers where sampler.isFormatCombo {
            guard let slot = sampler.textureSlot, slot > 0, headers[slot] == nil, let name = sampler.defaultTexture,
                  !name.isEmpty, !name.hasPrefix("_rt_") else { continue }
            headers[slot] = textureHeader(name, materialPath: materialPath)
        }
        return headers
    }

    static let texClampUVsFlag: UInt32 = 2

    /// nil (logged) for a texture that isn't there: the slot stays unbound, and so does its combo.
    private func textureInput(named name: String, materialPath: String) throws -> SceneEffectTextureInput? {
        if name == "_rt_FullFrameBuffer" { return .sceneSnapshot }
        if name == SceneMipMappedFrameBuffer.name { return .mipMappedFrameBuffer }
        // The frame's shadow atlas (`ImageMaterialRenderer.Draw.shadowAtlas`).
        if name == SceneShadowAtlas.name { return .fbo(name) }
        // The scene's light cookie this frame (genericimage4's `g_Texture7`; `frame.lighting.cookie`).
        if name == SceneLightCookie.name { return .fbo(name) }
        if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") {
            throw ImageMaterialPlanError.unsupported("render target \(name)")
        }
        guard let source = loadTexture(name, materialPath) else {
            OWELog.error(.scene, "Texture \(name) not found for \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
    }
}
