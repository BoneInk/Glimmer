//
//  SceneContentLoader+Particles.swift
//  Open Wallpaper Engine
//
//  Particle systems: the budget, families, shared parts, materials and sprite sheets.
//

import SwiftUI
import CoreText
import CryptoKit
import OWESceneEditing

extension SceneContentLoader {
    /// Thins the scene's particle systems to the user's budget (`ParticleBudget`), logging it once
    /// per scene and budget.
    func applyParticleBudget(to systems: inout [SceneMetalParticleSystem], wallpaperDir: URL) {
        let report = ParticleBudget.apply(renderSettings.particleBudget.limit, to: &systems)
        particleBudgetScale = report?.scale ?? 1
        guard let report, loggedParticleBudget?.directory != wallpaperDir || loggedParticleBudget?.report != report else { return }
        loggedParticleBudget = (wallpaperDir, report)
        OWELog.info(.scene, String(format: "%@: %d particles authored over the budget of %d; every system's maximum and rate × %.3f",
                                   wallpaperDir.lastPathComponent, report.authored, report.budget, report.scale))
    }

    /// A particle object's system followed by its children (`ParticleFamilyBuilder`).
    /// WE's particle defaults are in pixels in an orthographic scene (its parser's flag,
    /// `wallpaper64.exe` 0x14018768a, set with the scene's ortho bit), in world units otherwise.
    static func particlesUsePixelUnits(_ scene: WEScene) -> Bool {
        !scene.general.projection.isPerspective
    }

    func buildParticleFamily(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>, pixelUnits: Bool,
                                     transforms: SceneTransformHierarchy,
                                     cache: ParticleDefinitionCache) -> [SceneMetalParticleSystem] {
        OWEPhaseTiming.measure(.particlesModels) {
            buildParticleFamilyUntimed(object, id: id, wallpaperDir: wallpaperDir, sceneSize: sceneSize, pixelUnits: pixelUnits,
                                       transforms: transforms, cache: cache)
        }
    }

    private func buildParticleFamilyUntimed(_ object: WESceneObject, id: Int, wallpaperDir: URL, sceneSize: SIMD2<Float>,
                                            pixelUnits: Bool, transforms: SceneTransformHierarchy,
                                            cache: ParticleDefinitionCache) -> [SceneMetalParticleSystem] {
        guard let particlePath = object.particle else { return [] }
        // The emitter's full world transform: its own and its parents' origin, scale and angle.
        let world = object.id.map { transforms.world(of: String($0)) }
            ?? SceneAffineTransform(SceneLocalTransform(object: object))
        let builder = ParticleFamilyBuilder(
            load: { [weak self] path in self?.loadJSON(path: path, wallpaperDir: wallpaperDir) },
            build: { [weak self] path, system, world, overrides in
                self?.buildMetalParticleSystem(path, particleSystem: system, object: object, id: id, world: world,
                                               overrides: overrides, sceneSize: sceneSize, pixelUnits: pixelUnits,
                                               wallpaperDir: wallpaperDir, cache: cache)
            },
            report: { message in OWELog.error(.scene, "Particle object \(id): \(message)") })
        var family = builder.family(particlePath, world: world,
                                    overrides: SceneParticleOverrides(object.instanceoverride, in: userValueContext))
        // Only the root is the object; its children follow it through their links.
        for index in family.indices.dropFirst() { family[index].objectID = nil }
        if !family.isEmpty {
            family[0].emitterImages = ParticleEmitterImage.bound(object.dependencies ?? [])
            family[0].collisionModels = ParticleCollision.linkedModels(object.dependencies ?? [])
        }
        return family
    }

    /// Logs where a build's particle systems spent their time (`ParticleBuildTiming`).
    func logParticleBuildTiming(_ timing: ParticleBuildTiming, wallpaperDir: URL) {
        guard let summary = timing.summary else { return }
        Self.logDetail("\(wallpaperDir.lastPathComponent): \(summary)")
    }

    private func buildMetalParticleSystem(_ particlePath: String, particleSystem: WEParticleSystem, object: WESceneObject, id: Int,
                                          world: SceneAffineTransform, overrides: SceneParticleOverrides,
                                          sceneSize: SIMD2<Float>, pixelUnits: Bool, wallpaperDir: URL,
                                          cache: ParticleDefinitionCache) -> SceneMetalParticleSystem? {
        guard let materialPath = particleSystem.material else { return nil }
        // The object's blending is its own system's; the children it spawns keep their materials'.
        let blending = particlePath == object.particle ? blendingOverride(for: object) : nil
        // Every copy of a definition shares what its definition, material and blending decide;
        // the rest is the copy's own.
        let key = ParticleDefinitionCache.Key(particlePath: particlePath, materialPath: materialPath,
                                              blending: blending?.rawValue)
        let table = bindingTable
        guard let parts = cache.parts(for: key, noteReads: { table.noteReads($0) }, build: {
            table.capturingReads {
                buildSharedParticleParts(particlePath, materialPath: materialPath, particleSystem: particleSystem,
                                         blending: blending, object: object, id: id, wallpaperDir: wallpaperDir,
                                         timing: cache.timing)
            }
        }) else { return nil }
        return makeParticleSystem(particlePath, parts: parts, particleSystem: particleSystem, object: object, world: world,
                                  overrides: overrides, sceneSize: sceneSize, pixelUnits: pixelUnits,
                                  timing: cache.timing)
    }

    /// What every copy of a particle definition with the same material and blending draws with:
    /// the material, texture 0, its sprite sheet, each renderer's material plan and the built-in
    /// draw's texture. Nil when the system can't draw (no material or texture).
    private func buildSharedParticleParts(_ particlePath: String, materialPath: String, particleSystem: WEParticleSystem,
                                          blending: WEMaterialBlending?, object: WESceneObject, id: Int,
                                          wallpaperDir: URL, timing: ParticleBuildTiming) -> ParticleSharedParts? {
        guard var material: WEMaterial = timing.measure(.materialDocument, {
                  loadJSON(path: materialPath, wallpaperDir: wallpaperDir)
              }),
              let textureName = material.passes?.first?.textures?.first ?? nil else { return nil }
        if let blending { material.passes?[0].blending = blending.rawValue }
        guard let source = timing.measure(.texture, {
            loadMetalTexture(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir, colour: true)
        }) else {
            OWELog.error(.scene, "\(wallpaperDir.lastPathComponent): particle \(particlePath) (object \(id)): "
                         + "texture \(textureName) of \(materialPath) not found")
            return nil
        }
        let spriteSheet = timing.measure(.spriteSheet) {
            loadSpriteSheet(named: textureName, materialDir: materialPath, wallpaperDir: wallpaperDir, source: source)
        }
        let renderers = particleSystem.renderer ?? []
        let materialPlan = timing.measure(.materialPlan) {
            buildParticleMaterial(materialPath, particleSystem: particleSystem, renderer: renderers.first, source: source,
                                  spriteSheet: spriteSheet, blending: blending, object: object, id: id, wallpaperDir: wallpaperDir)
        }
        let fallbackSource = timing.measure(.fallbackTexture) { () -> SceneMetalTextureSource? in
            let albedo = ParticleMaterialPlanBuilder.textureHeader(named: textureName, materialPath: materialPath) {
                assetData(named: $0, wallpaperDir: wallpaperDir)
            }
            return ParticleFallbackTexture.converted(source, format: albedo.flatMap(TEXImageFormat.init(texData:)))
        }
        // WE draws every renderer of the system from its one simulation, each through the material
        // with that renderer's combos.
        let rendererMaterials = timing.measure(.extraRenderers) {
            renderers.dropFirst().map { renderer in
                buildParticleMaterial(materialPath, particleSystem: particleSystem, renderer: renderer, source: source,
                                      spriteSheet: spriteSheet, blending: blending, object: object, id: id,
                                      wallpaperDir: wallpaperDir)
            }
        }
        return ParticleSharedParts(material: material, source: source, spriteSheet: spriteSheet, materialPlan: materialPlan,
                                   fallbackSource: fallbackSource, rendererMaterials: rendererMaterials)
    }

    /// One copy's system: its own transform, overrides and object over the shared `parts`.
    private func makeParticleSystem(_ particlePath: String, parts: ParticleSharedParts, particleSystem: WEParticleSystem,
                                    object: WESceneObject, world: SceneAffineTransform, overrides: SceneParticleOverrides,
                                    sceneSize: SIMD2<Float>, pixelUnits: Bool,
                                    timing: ParticleBuildTiming) -> SceneMetalParticleSystem {
        var system = timing.measure(.system) {
            ParticleSystemBuilder.build(particlePath, particleSystem: particleSystem, object: object, world: world,
                                        overrides: overrides, sceneSize: sceneSize, source: parts.source,
                                        spriteSheet: parts.spriteSheet, material: parts.material,
                                        materialPlan: parts.materialPlan, pixelUnits: pixelUnits)
        }
        system.material = parts.materialPlan
        system.fallbackSource = parts.fallbackSource
        var rendererMaterials = parts.rendererMaterials.makeIterator()
        ParticleSystemBuilder.addRenderers(to: &system, particleSystem: particleSystem) { _ in
            rendererMaterials.next() ?? nil
        }
        return system
    }

    /// The system's material through WE's particle shaders; nil (logged when it's a failure)
    /// keeps the built-in particle draw.
    private func buildParticleMaterial(_ materialPath: String, particleSystem: WEParticleSystem,
                                       renderer: WEParticleRenderer?, source: SceneMetalTextureSource,
                                       spriteSheet: SpriteSheet?, blending: WEMaterialBlending?, object: WESceneObject,
                                       id: Int, wallpaperDir: URL) -> ParticleMaterialPlan? {
        guard let translator = effectTranslator else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            particleMaterialPlanTime.nanoseconds += DispatchTime.now().uptimeNanoseconds - start
            particleMaterialPlanTime.plans += 1
        }
        let builder = ParticleMaterialPlanBuilder(
            translator: translator,
            readFile: { [weak self] path in self?.assetData(named: path, wallpaperDir: wallpaperDir) },
            loadTexture: { [weak self] name, path in self?.loadMetalTexture(named: name, materialDir: path, wallpaperDir: wallpaperDir) },
            sceneEngineCombos: sceneEngineCombos, blending: blending)
        do {
            return try builder.build(materialPath: materialPath, renderer: renderer, flags: particleSystem.flags ?? 0,
                                     baseTexture: source, spriteSheet: spriteSheet)
        } catch {
            OWELog.error(.scene, "Particle system \(id) uses the built-in draw, material \(materialPath): \(error)")
            return nil
        }
    }

    /// One line: the content build's particle material plans and their time, and how many
    /// shader parses and geometry folds came from the translator's memo (`ShaderSourceMemo`).
    func logParticleMaterialPlanTime(wallpaperDir: URL, memoBefore: (hits: Int, misses: Int)?) {
        guard particleMaterialPlanTime.plans > 0 else { return }
        let memo = effectTranslator.map { translator -> String in
            let now = translator.sources.counts
            return ", shader memo \(now.hits - (memoBefore?.hits ?? 0)) hits, \(now.misses - (memoBefore?.misses ?? 0)) misses"
        } ?? ""
        Self.logDetail(String(format: "%@: particle material plans: %d in %.1f ms", wallpaperDir.lastPathComponent,
                              particleMaterialPlanTime.plans, Double(particleMaterialPlanTime.nanoseconds) / 1e6) + memo)
    }

    private func loadSpriteSheet(named name: String, materialDir: String, wallpaperDir: URL,
                                 source: SceneMetalTextureSource) -> SpriteSheet? {
        struct TextureMetadata: Decodable {
            struct Sequence: Decodable { let frames: Int; let width: Double; let height: Double; let duration: Double }
            let spritesheetsequences: [Sequence]?
        }
        let materialDirectory = (materialDir as NSString).deletingLastPathComponent
        let root = materialDirectory.split(separator: "/").first.map(String.init) ?? "materials"
        let candidates = ["\(materialDirectory)/\(name).tex-json", "\(root)/\(name).tex-json", "\(name).tex-json"]
        for candidate in candidates {
            let data = assetData(named: candidate, wallpaperDir: wallpaperDir)
            // Optional: a candidate that isn't sprite-sheet metadata is skipped for the next one.
            guard let data, let metadata = try? JSONDecoder().decode(TextureMetadata.self, from: data),
                  let sequence = metadata.spritesheetsequences?.first, sequence.frames > 0,
                  sequence.width > 0, sequence.height > 0 else { continue }
            guard let textureSize = source.sheetPixelSize else { continue }
            return SpriteSheet(frames: sequence.frames, frameSize: SIMD2(sequence.width, sequence.height),
                               duration: Float(sequence.duration), textureSize: textureSize)
        }
        // No `.tex-json` (every compiled Workshop texture): the `.tex`'s own `TEXS` frames.
        if case let .animated(animation) = source, let textureSize = source.sheetPixelSize {
            return SpriteSheet(texFrames: animation.frames, textureSize: textureSize)
        }
        return nil
    }
}
