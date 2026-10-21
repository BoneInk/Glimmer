import Foundation
import simd

enum ParticleMaterialPlanError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, Error)
    case noStage(String, [String])

    var description: String {
        switch self {
        case .missing(let path): return "missing \(path)"
        case .invalid(let path, let error): return "\(path): \(error)"
        case .noStage(let shader, let reasons): return "\(shader): no usable stage (\(reasons.joined(separator: "; ")))"
        }
    }
}

/// Resolves a particle system's material for WE's particle shaders: the shader the renderer
/// needs, the combos WE's engine sets for it, textures, constants and the translated variants.
struct ParticleMaterialPlanBuilder {
    let translator: ShaderVariantTranslator
    /// Reads a file relative to the wallpaper, falling back to the WE assets (shaders included).
    let readFile: (String) -> Data?
    /// Loads a texture by WE name relative to a material path.
    let loadTexture: (_ name: String, _ materialPath: String) -> SceneMetalTextureSource?
    /// The combos WE's engine lays over every material of the scene (`SceneEngineCombos`).
    var sceneEngineCombos = SceneEngineCombos()
    /// The system's blending in place of its material's first pass's (Scene Edit / Export's,
    /// `sceneObjectBlendingKey`); nil keeps the material's.
    var blending: WEMaterialBlending?

    /// `baseTexture` is texture 0 as the system already loaded it; `spriteSheet` is set when it
    /// is a sheet. `flags` are the particle system's `flags`.
    func build(materialPath: String, renderer: WEParticleRenderer?, flags: Int, baseTexture: SceneMetalTextureSource,
               spriteSheet: SpriteSheet?) throws -> ParticleMaterialPlan {
        guard let data = readFile(materialPath) else { throw ParticleMaterialPlanError.missing(materialPath) }
        let material: MaterialDocument
        do {
            material = try decodeTolerant(MaterialDocument.self, from: data)
        } catch {
            throw ParticleMaterialPlanError.invalid(materialPath, error)
        }
        guard var pass = material.passes.first else { throw ParticleMaterialPlanError.missing("\(materialPath) passes") }
        if let blending { pass.blending = blending.rawValue }

        let rendererName = renderer?.name?.lowercased() ?? "sprite"
        let format = Self.vertexFormat(rendererName: rendererName)
        // WE's engine swaps its sprite shader for the rope one when a rope renderer draws it.
        let shader = format == .rope && Self.isBuiltinSpriteShader(pass.shader) ? "genericropeparticle" : pass.shader
        var engineCombos = Self.engineCombos(format: format, rendererName: rendererName, renderer: renderer,
                                             flags: flags, spriteSheet: spriteSheet, baseTexture: baseTexture)
        var headers: [Int: Data] = [:]
        for (slot, name) in pass.textures.enumerated() {
            if let name, let header = textureHeader(named: name, materialPath: materialPath) { headers[slot] = header }
        }
        engineCombos.merge(Self.textureFormatCombos(headers)) { _, new in new }

        var stages: [ParticleMaterialPlan.Stage] = []
        var failures: [String] = []
        do {
            if let geometry = try GeometryShaderEmulation.sources(shader, readFile: readFile) {
                stages.append(try stage(shader: shader, format: format, geometry: geometry, pass: pass, materialPath: materialPath,
                                        engineCombos: engineCombos.merging(["GS_ENABLED": 1]) { _, new in new },
                                        baseTexture: baseTexture))
            }
        } catch {
            failures.append("geometry stage: \(error)")
        }
        do {
            stages.append(try stage(shader: shader, format: format, geometry: nil, pass: pass, materialPath: materialPath,
                                    engineCombos: engineCombos.merging(["GS_ENABLED": 0]) { _, new in new },
                                    baseTexture: baseTexture))
        } catch {
            failures.append("vertex stage: \(error)")
        }
        guard !stages.isEmpty else { throw ParticleMaterialPlanError.noStage(shader, failures) }
        for failure in failures {
            OWELog.error(.shader, "Particle material \(materialPath) (\(shader)): \(failure)")
        }
        var plan = ParticleMaterialPlan(materialPath: materialPath, shader: shader, format: format,
                                        blending: pass.blending?.lowercased() ?? "translucent", stages: stages,
                                        trailLengths: Self.trailLengths(renderer), spriteSheet: spriteSheet)
        for (slot, header) in headers {
            if let flags = TEXFlags(texData: header) { plan.textureFlags[slot] = flags }
        }
        plan.raster = SceneRasterState(depthtest: pass.depthtest, depthwrite: pass.depthwrite, cullmode: pass.cullmode,
                                       blending: plan.blending)
        return plan
    }

    /// A material texture's `.tex` file, found where the scene loader looks for it: next to the
    /// material, under its root folder, then under `materials/`. Nil for a texture that isn't a
    /// `.tex` (render targets, generated textures).
    private func textureHeader(named name: String, materialPath: String) -> Data? {
        Self.textureHeader(named: name, materialPath: materialPath, readFile: readFile)
    }

    static func textureHeader(named name: String, materialPath: String, readFile: (String) -> Data?) -> Data? {
        guard !name.hasPrefix("_rt_") else { return nil }
        let directory = (materialPath as NSString).deletingLastPathComponent
        let root = directory.split(separator: "/").first.map(String.init) ?? "materials"
        for path in ["\(directory)/\(name).tex", "\(root)/\(name).tex", "materials/\(name).tex", "\(name).tex"] {
            if let data = readFile(path) { return data }
        }
        return nil
    }

    /// `TEX<n>FORMAT` for the textures the GPU samples as stored, as WE sets it from each bound
    /// texture: `DecompressNormal` reads a block-compressed or RG88 normal map's channels by it, and
    /// `ConvertTexture0Format` turns an RG88 albedo (stored as (r, g, 0, 1)) into `.rrrg` and an R8
    /// one (stored as (r, 0, 0, 1)) into (1, 1, 1, r). The formats `TEXParser` expands to RGBA stay
    /// `FORMAT_RGBA8888`, as does a block-compressed texture 0, which no particle shader converts.
    static func textureFormatCombos(_ headers: [Int: Data]) -> [String: Int] {
        var combos: [String: Int] = [:]
        for (slot, header) in headers {
            guard let format = TEXImageFormat(texData: header),
                  format.isChannelReduced || (format.isBlockCompressed && slot > 0) else { continue }
            combos["TEX\(slot)FORMAT"] = Int(format.rawValue)
        }
        return combos
    }

    static func isBuiltinSpriteShader(_ shader: String) -> Bool {
        let name = shader.hasPrefix("shaders/") ? String(shader.dropFirst("shaders/".count)) : shader
        return name == "genericparticle"
    }

    /// Particle system flag: sprite sheets step between frames instead of blending them.
    static let noFrameBlendingFlag = 2

    /// The combos WE's engine sets from the particle system rather than the material (as
    /// linux-wallpaperengine and wallpaper-scene-renderer set them).
    /// Strips for WE's `rope` and `ropetrail`, quads for every other renderer.
    static func vertexFormat(rendererName: String) -> ParticleVertexFormat {
        WEParticleRendererType(rawValue: rendererName)?.isRope == true ? .rope : .sprite
    }

    static func engineCombos(format: ParticleVertexFormat, rendererName: String, renderer: WEParticleRenderer?,
                             flags: Int, spriteSheet: SpriteSheet?, baseTexture: SceneMetalTextureSource) -> [String: Int] {
        var combos: [String: Int] = [:]
        switch format {
        case .sprite:
            let trail = rendererName == "spritetrail"
            if trail { combos["TRAILRENDERER"] = 1 }
            if spriteSheet != nil {
                combos["SPRITESHEET"] = 1
                if flags & noFrameBlendingFlag == 0 { combos["SPRITESHEETBLEND"] = 1 }
                // A sheet inside a padded texture addresses frames in content units.
                if case .dxt(let texture) = baseTexture, texture.contentWidth != texture.width {
                    combos["SPRITESHEETBLENDNPOT"] = 1
                }
            }
            // The thick stream carries velocity and lifetime, which trails and sheets read.
            if trail || spriteSheet != nil { combos["THICKFORMAT"] = 1 }
        case .rope:
            // Per-segment end colour and size are always known.
            combos["THICKFORMAT"] = 1
            if rendererName == "ropetrail" {
                combos["TRAILRENDERER"] = 1
                // A scrolling trail's texture moves along it (0x1401d261b…0x1401d2976).
                if renderer?.uvscrolling == true { combos["TRAILSCROLLALPHA"] = 1 }
            }
            // WE's subdivision: 4 for `rope`, 1 for `ropetrail` (`ParticleRendererDefaults`).
            combos["TRAILSUBDIVISION"] = ParticleRendererDefaults(renderer).subdivision
            // The renderer's orientation: 0 faces the ribbon to the eye, else along
            // `g_OrientationForward` (0x1401d271b / 0x1401d2b3e).
            combos["ORIENTATION"] = ParticleOrientation(renderer).mode.rawValue
        }
        return combos
    }

    /// `g_RenderVar0` of a sprite trail: `(length, maxlength, minlength, 0)` with WE's renderer
    /// defaults (`ParticleRendererDefaults`).
    static func trailLengths(_ renderer: WEParticleRenderer?) -> SIMD4<Float> {
        let trail = ParticleRendererDefaults(renderer)
        return SIMD4(trail.length, trail.maximumLength, trail.minimumLength, 0)
    }

    /// One stage: with `geometry`, its geometry stage emulated; without, WE's no-geometry-shader
    /// vertex stage expanded per instance.
    private func stage(shader: String, format: ParticleVertexFormat, geometry: GeometryShaderEmulation.Sources?,
                       pass: MaterialPass, materialPath: String,
                       engineCombos: [String: Int], baseTexture: SceneMetalTextureSource) throws -> ParticleMaterialPlan.Stage {
        let reader = readFile
        let memo = translator.sources
        // Rewritten vertex stages are served to the loader under names of their own; the variant
        // cache keys on the text, so they never collide with the authored stage.
        func synthetic(_ path: String, _ text: String) throws -> ShaderSource {
            let data = Data(text.utf8)
            return try ShaderSourceLoader(readFile: { $0 == path ? data : reader($0) }, memo: memo).load(path, stage: .vertex)
        }
        let fragment = try ShaderSourceLoader(readFile: reader, memo: memo).load(shader, stage: .fragment)
        // What the stages declare (combos, uniforms and their material keys), before any rewrite.
        let declarations = try geometry.map { try synthetic("shaders/\(shader)+declarations.vert", $0.declarations) }
            ?? ShaderSourceLoader(readFile: reader, memo: memo).load(shader, stage: .vertex)

        var inputs: [Int: SceneEffectTextureInput] = [0: .asset(key: "\(materialPath)|particle0", source: baseTexture)]
        for (slot, name) in pass.textures.enumerated() where slot > 0 {
            if let name, let input = textureInput(named: name, materialPath: materialPath) { inputs[slot] = input }
        }
        let combos = sceneEngineCombos.applied(to: ShaderVariantTranslator.resolveCombos(
            vertex: declarations, fragment: fragment, overrides: [pass.combos, engineCombos],
            boundTextureSlots: Set(inputs.keys)))
        let vertex: ShaderSource
        let stageGeometry: ParticleMaterialPlan.Stage.Geometry
        if let geometry {
            let emulation = try memo.geometryEmulation(geometry, combos: combos, compiler: translator.compiler)
            vertex = try synthetic("shaders/\(shader)+geom.vert", emulation.vertexText)
            stageGeometry = .emulated(vertexCount: try emulation.vertexCountPerInstance(combos: combos),
                                      restartsStrips: emulation.restartsStrips)
        } else {
            vertex = try synthetic("shaders/\(shader)+quads.vert", ParticleQuadExpansion.rewrite(declarations.text, format: format))
            stageGeometry = .expandedQuads
        }
        let variant = try translator.variant(vertex: vertex, fragment: fragment, combos: combos)
        let sampled = Set(variant.textureSlots)
        inputs = inputs.filter { sampled.contains($0.key) }
        for sampler in declarations.samplers + fragment.samplers {
            guard let slot = sampler.textureSlot, sampled.contains(slot), inputs[slot] == nil,
                  let name = sampler.defaultTexture,
                  let input = textureInput(named: name, materialPath: materialPath) else { continue }
            inputs[slot] = input
        }
        let uniforms = ShaderUniformDeclaration.merged(vertex: declarations.uniforms, fragment: fragment.uniforms)
        let constants = ShaderConstantResolver.resolve(
            uniforms: uniforms.map { .init(name: $0.name, glslType: $0.type, arrayCount: $0.arrayCount ?? 1, annotation: $0.annotation) },
            material: pass.constantSources(uniforms: uniforms), instance: [:])
        return ParticleMaterialPlan.Stage(geometry: stageGeometry, variant: variant,
                                          variantKey: ShaderVariantTranslator.cacheKey(vertex: vertex, fragment: fragment, combos: combos),
                                          textures: inputs, constants: constants)
    }

    private func textureInput(named name: String, materialPath: String) -> SceneEffectTextureInput? {
        if name == "_rt_FullFrameBuffer" { return .sceneSnapshot }
        if name == SceneMipMappedFrameBuffer.name { return .mipMappedFrameBuffer }
        // The frame's shadow atlas (`ParticleMaterialRenderer.DrawContext.shadowAtlas`).
        if name == SceneShadowAtlas.name { return .fbo(name) }
        if name.hasPrefix("_rt_") {
            OWELog.error(.scene, "Unsupported render target \(name) in particle material \(materialPath)")
            return nil
        }
        guard let source = loadTexture(name, materialPath) else {
            OWELog.error(.scene, "Texture \(name) not found for particle material \(materialPath)")
            return nil
        }
        return .asset(key: "\(materialPath)|\(name)", source: source)
    }
}
