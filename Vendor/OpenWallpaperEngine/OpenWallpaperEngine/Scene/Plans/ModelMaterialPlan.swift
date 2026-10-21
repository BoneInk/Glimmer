import Foundation

/// One mesh's material, resolved at load (docs/models-plan.md §2.7, §4.3 M5): the variant WE's
/// shader translates to with the material's combos, the engine's (`SceneEngineCombos`) and the
/// mesh's (`ModelMeshCombos`), its textures, constants, blending and pass state. Every model
/// shader goes through here, WE's `generic*` and a project's own (`car`, `technoorbit`, …). A
/// final class so the renderer can key per-mesh state on its identity.
final class ModelMaterialPlan {
    /// The material JSON, for logging.
    let materialPath: String
    /// `variant`, textures (every slot an asset, `_rt_MipMappedFrameBuffer` or the engine's
    /// morph texture), constants and blending.
    let pass: SceneEffectPassPlan
    /// The first pass's `depthtest`, `depthwrite` and `cullmode`, with WE's defaults (test,
    /// write, back faces culled).
    let raster: SceneRasterState
    /// Texture slots sampled with clamp-to-edge (the `.tex` ClampUVs flag); the others repeat.
    let clampedSlots: Set<Int>
    let meshCombos: ModelMeshCombos
    /// The material's "shadow" variant (docs/models-plan.md §2.10), which draws the mesh into the
    /// shadow atlas: made for an opaque material while the scene's light budget has a shadowed
    /// light and the shadows setting is on; nil otherwise.
    let shadowCaster: ModelMaterialPlan?
    /// The pass's shader is the wallpaper's own, not one of WE's (`ModelMaterialPlanBuilder.isBuiltinShader`):
    /// only then does a mesh lacking an input the shader reads draw nothing (`SceneModelMissingInputs`).
    let customShader: Bool
    /// How many instances each draw of the mesh is: the pass's resolved `INSTANCECOUNT` combo when
    /// its shader declares one (`fur4`'s shells, "Fur quality" 5, 9, 13 or 21, each instance
    /// pushed out along the normal by `gl_InstanceID / (INSTANCECOUNT - 1)`), else 1.
    let instanceCount: Int
    /// The material's passes after the first, in its order: each draws the mesh again right after
    /// the one before, through its own shader, combos, textures, constants, blending and depth and
    /// cull state, as a material's passes draw everywhere in WE (an effect's or an image's). The
    /// model's place in the draw order and its shadow variant are the first pass's.
    let laterPasses: [ModelMaterialPlan]

    init(materialPath: String, pass: SceneEffectPassPlan, raster: SceneRasterState, clampedSlots: Set<Int>,
         meshCombos: ModelMeshCombos, shadowCaster: ModelMaterialPlan? = nil, customShader: Bool, instanceCount: Int = 1,
         laterPasses: [ModelMaterialPlan] = []) {
        self.materialPath = materialPath
        self.pass = pass
        self.raster = raster
        self.clampedSlots = clampedSlots
        self.meshCombos = meshCombos
        self.shadowCaster = shadowCaster
        self.customShader = customShader
        self.instanceCount = max(1, instanceCount)
        self.laterPasses = laterPasses
    }

    /// Every pass of the material in drawing order: this one, then `laterPasses`.
    var passes: [ModelMaterialPlan] { [self] + laterPasses }

    /// WE's blending byte (+0x1f0): normal 0, translucent 1, additive 2, alphatocoverage 3.
    var blending: String { pass.blending.lowercased() }
    /// Blending normal or alpha-to-coverage: the mesh makes its model opaque (0x140225241) and
    /// draws before the translucent meshes (0x14021a620). Anything else is translucent.
    var isOpaque: Bool { ["normal", "alphatocoverage", "disabled", ""].contains(blending) }
    var alphaToCoverage: Bool { blending == "alphatocoverage" }
}

/// The combos WE's model builder lays over each mesh's material (0x140224c70; docs/models-plan.md
/// §2.7): `SKINNING` when the mesh has `a_BlendIndices`, `BONECOUNT` =
/// `min(nextPow2(max(bones, 16)), 128)` (16, 32, 64 or 128; a puppet's is exact instead),
/// `MORPHING` when the mesh has morph targets and `MORPHING_NORMALS` with mesh flag 0x400.
struct ModelMeshCombos: Hashable {
    var skinning: Bool
    var boneCount: Int
    var morphing: Bool
    var morphingNormals: Bool

    init(skinning: Bool, boneCount: Int, morphing: Bool = false, morphingNormals: Bool = false) {
        self.skinning = skinning
        self.boneCount = boneCount
        self.morphing = morphing
        self.morphingNormals = morphingNormals
    }

    /// `mesh` of a model with `bones` bones; `morphTargets` says whether the model's `MDMP` has
    /// targets for it.
    init(mesh: MDLMesh, bones: Int, morphTargets: Bool) {
        self.init(skinning: mesh.format.contains(.blendIndices), boneCount: Self.boneCount(bones),
                  morphing: morphTargets, morphingNormals: morphTargets && mesh.flags & 0x400 != 0)
    }

    /// `min(nextPow2(max(bones, 16)), 128)`.
    static func boneCount(_ bones: Int) -> Int {
        var count = 16
        while count < bones, count < 128 { count *= 2 }
        return count
    }

    var combos: [String: Int] {
        var combos = ["SKINNING": skinning ? 1 : 0, "BONECOUNT": boneCount]
        if morphing { combos["MORPHING"] = 1 }
        if morphingNormals { combos["MORPHING_NORMALS"] = 1 }
        return combos
    }

    /// `g_Texture5`, WE's "morph" texture of position (and normal) deltas: the engine binds it.
    static let morphSlot = 5
}

/// Builds a mesh's `ModelMaterialPlan` from its material JSON.
struct ModelMaterialPlanBuilder {
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper, falling back to the WE assets.
    let readFile: (String) -> Data?
    /// Loads a texture by WE name relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?
    /// The combos WE's engine lays over every material of the scene (`LIGHTS_*`, `HDR`, `FOG_*`,
    /// `REVERSEDEPTH`).
    var sceneEngineCombos = SceneEngineCombos()
    /// Whether a pass's `shader` is one of WE's own, in its assets (`generic4`, `shadowcaster`, …)
    /// rather than the wallpaper's. Nil treats every shader as the wallpaper's.
    var isBuiltinShader: ((String) -> Bool)?

    func build(materialPath: String, mesh: ModelMeshCombos) throws -> ModelMaterialPlan {
        guard let data = readFile(materialPath) else { throw ModelMaterialPlanError.missing(materialPath) }
        let material: MaterialDocument
        do {
            material = try decodeTolerant(MaterialDocument.self, from: data)
        } catch {
            throw ModelMaterialPlanError.invalid(materialPath, error)
        }
        guard let first = material.passes.first else { throw ModelMaterialPlanError.missing("\(materialPath) passes") }
        // A later pass that can't be made is logged and left out; the others draw.
        var later: [ModelMaterialPlan] = []
        for (index, materialPass) in material.passes.enumerated().dropFirst() {
            do {
                later.append(try build(materialPass, materialPath: materialPath, mesh: mesh, first: false))
            } catch {
                OWELog.error(.scene, "Model material \(materialPath)'s pass \(index + 1) can't be made; it isn't drawn: \(error)")
            }
        }
        return try build(first, materialPath: materialPath, mesh: mesh, first: true, laterPasses: later)
    }

    /// One pass of a material; only the `first` gets a shadow variant (the material's caster is
    /// its first pass's, docs/models-plan.md §2.10).
    private func build(_ materialPass: MaterialPass, materialPath: String, mesh: ModelMeshCombos, first: Bool,
                       laterPasses: [ModelMaterialPlan] = []) throws -> ModelMaterialPlan {
        let loader = ShaderSourceLoader(readFile: readFile, memo: translator.sources)
        let vertex = try loader.load(materialPass.shader, stage: .vertex)
        let fragment = try loader.load(materialPass.shader, stage: .fragment)
        let images = ImageMaterialPlanBuilder(translator: translator, readFile: readFile, loadTexture: loadTexture,
                                              sceneEngineCombos: sceneEngineCombos)

        var listed: [Int: SceneEffectTextureInput] = [:]
        var headers: [Int: Data] = [:]
        for (slot, name) in materialPass.textures.enumerated() {
            guard let name, !name.isEmpty else { continue }
            listed[slot] = try textureInput(named: name, materialPath: materialPath)
            if listed[slot] != nil, !name.hasPrefix("_rt_") { headers[slot] = images.textureHeader(name, materialPath: materialPath) }
        }
        let formats = ImageMaterialPlanBuilder.formatCombos(
            vertex.samplers + fragment.samplers,
            headers: images.formatHeaders(vertex.samplers + fragment.samplers, listed: headers, materialPath: materialPath))
        // A pass blending alpha-to-coverage gets `ALPHATOCOVERAGE` (0x140154bc1, 0x1401564a4), an
        // additive one `ADDITIVE` (0x140154c5a).
        let coverage = ImageMaterialPlanBuilder.blendingCombos(blending: materialPass.blending)
        let combos = sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
            vertex: vertex, fragment: fragment, overrides: [materialPass.combos, coverage, mesh.combos, formats],
            boundTextureSlots: Set(listed.keys),
            textureFlags: headers.compactMapValues { TEXHeader.texiWord(1, in: $0) }))

        let uniforms = (vertex.uniforms + fragment.uniforms).filter { !$0.isSampler }
            .reduce(into: [ShaderUniformDeclaration]()) { result, uniform in
                if !result.contains(where: { $0.name == uniform.name }) { result.append(uniform) }
            }
        let constants = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: materialPass.constantSources(uniforms: uniforms), instance: [:])

        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        // SPIRV-Cross emits only the textures a stage uses; one it doesn't emit needs nothing bound.
        let msl = variant.vertexMSL + variant.fragmentMSL
        let sampled = Set(variant.textureSlots).filter { msl.contains("[[texture(\($0))]]") }
        var inputs = listed.filter { sampled.contains($0.key) }
        for sampler in vertex.samplers + fragment.samplers {
            guard let slot = sampler.textureSlot, sampled.contains(slot), inputs[slot] == nil,
                  let name = sampler.defaultTexture else { continue }
            inputs[slot] = try textureInput(named: name, materialPath: materialPath)
        }
        let engineBound: Set<Int> = mesh.morphing ? [ModelMeshCombos.morphSlot] : []
        if let unbound = sampled.subtracting(inputs.keys).subtracting(engineBound).min() {
            throw ModelMaterialPlanError.unsupported("g_Texture\(unbound) has no texture")
        }
        let pass = SceneEffectPassPlan(command: .render,
                                       variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                       variant: variant, blending: materialPass.blending ?? "normal", target: nil,
                                       textures: inputs, constants: constants)
        var clampedSlots = Set<Int>()
        for (slot, input) in inputs {
            switch input {
            case .mipMappedFrameBuffer: clampedSlots.insert(slot)
            case .asset(let key, _):
                if images.textureClamps(String(key.dropFirst(materialPath.count + 1)), materialPath: materialPath) {
                    clampedSlots.insert(slot)
                }
            default: break
            }
        }
        var shadowCaster: ModelMaterialPlan?
        if first, sceneEngineCombos.castsShadows, ["normal", "alphatocoverage", "disabled", ""].contains(pass.blending.lowercased()) {
            do {
                shadowCaster = try buildShadowCaster(
                    ShadowCasterSource(materialPath: materialPath, pass: materialPass, vertex: vertex, fragment: fragment,
                                       combos: combos, textures: inputs, clampedSlots: clampedSlots, mesh: mesh))
            } catch {
                OWELog.error(.shader, "Model material \(materialPath)'s shadow variant can't be made; its meshes cast no shadow: \(error)")
            }
        }
        return ModelMaterialPlan(materialPath: materialPath, pass: pass,
                                 raster: SceneRasterState(depthtest: materialPass.depthtest, depthwrite: materialPass.depthwrite,
                                                          cullmode: materialPass.cullmode, blending: materialPass.blending),
                                 clampedSlots: clampedSlots, meshCombos: mesh, shadowCaster: shadowCaster,
                                 customShader: isCustom(materialPass.shader),
                                 instanceCount: Self.instanceCount(vertex: vertex, fragment: fragment, combos: combos),
                                 laterPasses: laterPasses)
    }

    /// The instances a pass draws: its `INSTANCECOUNT` combo's value when either stage declares
    /// that combo (`fur4.frag`'s "Fur quality"), else 1.
    static func instanceCount(vertex: ShaderSource, fragment: ShaderSource, combos: [String: Int]) -> Int {
        guard (vertex.combos + fragment.combos).contains(where: { $0.name == instanceCountCombo }),
              let count = combos[instanceCountCombo] else { return 1 }
        return max(1, count)
    }

    /// The combo naming a pass's instance count.
    static let instanceCountCombo = "INSTANCECOUNT"

    /// What a material's shadow variant takes from it.
    struct ShadowCasterSource {
        let materialPath: String
        let pass: MaterialPass
        let vertex: ShaderSource
        let fragment: ShaderSource
        /// The material's resolved combos.
        let combos: [String: Int]
        let textures: [Int: SceneEffectTextureInput]
        let clampedSlots: Set<Int>
        let mesh: ModelMeshCombos
    }

    /// WE's shadow variant of a material pass (0x140155fc0, docs/models-plan.md §2.10): the shader
    /// its source names in a `// [PASS] shadow <name>` header (0x14016de11: `fur4` →
    /// `shadowcasterfur4`, `foliage4` → `shadowcasterfoliage4`), else `materials/util/
    /// shadowcaster.json`'s; every combo the caster declares takes the material's value (0 where
    /// the material has none); `ALPHATOCOVERAGE` = 1 with alpha-to-coverage blending when the
    /// material blends so (0x1401564a4); the util material's pass state; the material's
    /// constants; its textures by slot (the albedo an alpha-to-coverage caster reads), the
    /// engine's morph texture for a caster's "morph" sampler.
    func buildShadowCaster(_ source: ShadowCasterSource) throws -> ModelMaterialPlan {
        guard let data = readFile(Self.shadowCasterMaterial) else { throw ModelMaterialPlanError.missing(Self.shadowCasterMaterial) }
        let util: MaterialDocument
        do {
            util = try decodeTolerant(MaterialDocument.self, from: data)
        } catch {
            throw ModelMaterialPlanError.invalid(Self.shadowCasterMaterial, error)
        }
        guard let utilPass = util.passes.first else { throw ModelMaterialPlanError.missing("\(Self.shadowCasterMaterial) passes") }
        let shader = Self.shadowPassShader(in: source.fragment.text) ?? Self.shadowPassShader(in: source.vertex.text) ?? utilPass.shader
        let loader = ShaderSourceLoader(readFile: readFile, memo: translator.sources)
        let vertex = try loader.load(shader, stage: .vertex)
        let fragment = try loader.load(shader, stage: .fragment)
        var inherited: [String: Int] = [:]
        for declaration in vertex.combos + fragment.combos {
            inherited[declaration.name] = source.combos[declaration.name] ?? 0
        }
        let alphaToCoverage = source.pass.blending?.lowercased() == "alphatocoverage"
        let coverage = alphaToCoverage ? ["ALPHATOCOVERAGE": 1] : [:]
        let listed = source.textures
        let combos = sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
            vertex: vertex, fragment: fragment, overrides: [inherited, coverage], boundTextureSlots: Set(listed.keys)))
        let uniforms = ShaderUniformDeclaration.merged(vertex: vertex.uniforms.filter { !$0.isSampler },
                                                       fragment: fragment.uniforms.filter { !$0.isSampler })
        let constants = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: source.pass.constantSources(uniforms: uniforms), instance: [:])
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        let msl = variant.vertexMSL + variant.fragmentMSL
        let sampled = Set(variant.textureSlots).filter { msl.contains("[[texture(\($0))]]") }
        let morph = Set((vertex.samplers + fragment.samplers).filter { ($0.annotation["material"] as? String) == "morph" }
            .compactMap(\.textureSlot))
        let inputs = listed.filter { sampled.contains($0.key) && !morph.contains($0.key) }
        if let unbound = sampled.subtracting(inputs.keys).subtracting(morph).min() {
            throw ModelMaterialPlanError.unsupported("the shadow variant's g_Texture\(unbound) has no texture")
        }
        let pass = SceneEffectPassPlan(command: .render,
                                       variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                       variant: variant, blending: alphaToCoverage ? "alphatocoverage" : (utilPass.blending ?? "normal"),
                                       target: nil, textures: inputs, constants: constants)
        return ModelMaterialPlan(materialPath: "\(source.materialPath) (shadow: \(shader))", pass: pass,
                                 raster: SceneRasterState(depthtest: utilPass.depthtest, depthwrite: utilPass.depthwrite,
                                                          cullmode: utilPass.cullmode),
                                 clampedSlots: source.clampedSlots.intersection(inputs.keys), meshCombos: source.mesh,
                                 customShader: isCustom(shader))
    }

    private func isCustom(_ shader: String) -> Bool { !(isBuiltinShader?(shader) ?? false) }

    /// The util material every shadow variant takes its pass state (and its default shader) from.
    static let shadowCasterMaterial = "materials/util/shadowcaster.json"

    /// The shader a `// [PASS] shadow <name>` line names; nil without one.
    static func shadowPassShader(in text: String) -> String? {
        shadowPassPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            .flatMap { Range($0.range(at: 1), in: text) }
            .map { String(text[$0]) }
    }

    private static let shadowPassPattern = NSRegularExpression.shader(#"//[ \t]*\[PASS\][ \t]+shadow[ \t]+([\w/.-]+)"#)

    /// nil (logged) for a texture that isn't there: the slot stays unbound, and so does its combo.
    private func textureInput(named name: String, materialPath: String) throws -> SceneEffectTextureInput? {
        if name == SceneMipMappedFrameBuffer.name { return .mipMappedFrameBuffer }
        // Another layer's image after its effects (a dependency of the model, drawn whether it is
        // visible or not): the renderer hands it out by layer id (`SceneModelDraw.layerComposite`).
        if Self.compositeLayerID(name) != nil { return .fbo(name) }
        // The frame's shadow atlas (`SceneModelDraw.shadowAtlas`).
        if name == SceneShadowAtlas.name { return .fbo(name) }
        // The planar reflection (`SceneModelDraw.planarReflection`, `ScenePlanarReflection`).
        if name == ScenePlanarReflection.name { return .fbo(name) }
        // The scene's light cookie this frame (`SceneModelDraw.frame.lighting.cookie`).
        if name == SceneLightCookie.name { return .fbo(name) }
        if name.hasPrefix("_rt_") || name.hasPrefix("_alias_") {
            // The scene's other buffers have no source for a model yet.
            throw ModelMaterialPlanError.unsupported("render target \(name)")
        }
        guard let source = loadTexture(name, materialPath) else {
            OWELog.error(.scene, "Texture \(name) not found for \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
    }
}

extension ModelMaterialPlanBuilder {
    /// The layer id of `_rt_imageLayerComposite_<id>_a` (WE's buffer the layer's image and its
    /// effects are drawn into, 0x1401ea642); nil for any other name.
    static func compositeLayerID(_ name: String) -> String? {
        let prefix = "_rt_imageLayerComposite_"
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let end = rest.firstIndex(of: "_"), rest[rest.index(after: end)...] == "a" else { return nil }
        let id = rest[..<end]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? String(id) : nil
    }
}

enum ModelMaterialPlanError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, Error)
    case unsupported(String)

    var description: String {
        switch self {
        case .missing(let path): return "missing \(path)"
        case .invalid(let path, let error): return "\(path): \(error)"
        case .unsupported(let reason): return "unsupported: \(reason)"
        }
    }
}
