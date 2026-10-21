import Foundation
import CoreText
import Metal

/// Conservative readiness evidence for the public helper facade. This is intentionally separate
/// from the renderer: it observes authored plans and actual GPU state without rewriting effects,
/// replacing resources, enabling features or accepting a particular Workshop item by its ID.
enum GlimmerStrictReadiness {
    struct Baseline {
        let imageFallbacks: [String: Int]
        let particleFallbacks: Int
        let imageDraws: Int
        let particleDraws: Int
    }

    static func captureBaseline(renderer: SceneMetalRenderer) -> Baseline {
        Baseline(imageFallbacks: renderer.imageMaterialFallbacks,
                 particleFallbacks: renderer.particleMaterials?.fallbacksReported ?? 0,
                 imageDraws: renderer.imageMaterialDraws,
                 particleDraws: renderer.particleMaterials?.drawsEncoded ?? 0)
    }

    static func collect(content: SceneMetalContent, renderer: SceneMetalRenderer,
                        authoredObjects: [[String: Any]], scriptConsoleErrors: [String],
                        configuration: SceneBackendConfiguration,
                        readOriginalResource: (String) -> Data?,
                        steadyBaseline: Baseline? = nil) -> SceneBackendReadiness {
        var diagnostics: [SceneBackendDiagnostic] = []
        var missing = Set<String>(), fallbacks = Set<String>()
        var expected: [String] = [], accounted = Set<String>()
        var auditedSounds: [String] = []
        var pipelineFailures = renderer.effectGraph?.failedPipelineCount ?? 0
        var exactFonts = true, videosReady = true, auditComplete = true
        let roots = configuration.roots

        func problem(_ code: String, _ message: String, id: String? = nil, resource: String? = nil) {
            diagnostics.append(.init(code: code, resource: resource,
                message: id.map { "Object \($0): \(message)" } ?? message))
        }
        func valuePresent(_ object: [String: Any], _ key: String) -> Bool {
            guard let value = object[key] else { return false }
            return !(value is NSNull)
        }
        func safeData(_ path: String) -> Data? {
            guard AssetPathResolver.sanitize(path) == path else { return nil }
            // Use the loader's original package/loose/shared VFS in the same precedence as
            // rendering. A valid packed project need not expose package entries as loose files.
            guard let data = readOriginalResource(path), UInt64(data.count) <= AssetPathResolver.maxFileSize else { return nil }
            return data
        }
        func requireResource(_ path: String, id: String?) {
            guard !path.isEmpty, safeData(path) != nil else {
                missing.insert(path.isEmpty ? "<empty resource path>" : path)
                problem("missing.resource", "Required original resource is unavailable", id: id, resource: path)
                return
            }
        }

        let prepared = Set(renderer.layers.map { $0.layer.id })
        let layers = Dictionary(content.layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let particles = Set(content.particleSystems.compactMap(\.objectID))
        let sounds = Dictionary(content.sounds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        /// The files scene.json declares for a sound object. Upstream `WESceneSound`
        /// (Scene/Format/SceneSound.swift) decodes the object's top-level `sound` key, which is
        /// either the one-file string form or a list of paths; playback options (`playbackmode`,
        /// `volume`, ...) also live at the object top level, not in a nested `sound` dictionary.
        func authoredSoundFiles(_ object: [String: Any]) -> [String] {
            let declared: [String]
            if let one = object["sound"] as? String { declared = [one] }
            else if let list = object["sound"] as? [String] { declared = list }
            else { declared = [] }
            return declared.map { $0.replacingOccurrences(of: "\\", with: "/") }
        }
        var seen = Set<String>()
        for object in authoredObjects {
            guard let number = object["id"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, abs(number.doubleValue) <= 9_007_199_254_740_991,
                  number.doubleValue.rounded() == number.doubleValue else {
                auditComplete = false
                problem("unsupported.object_identity", "An authored object has no finite integer identity")
                continue
            }
            let id = String(number.int64Value)
            guard seen.insert(id).inserted else {
                auditComplete = false
                problem("unsupported.duplicate_identity", "Duplicate authored object identity", id: id)
                continue
            }
            let drawable = ["image", "particle", "text", "shape", "model"].contains { valuePresent(object, $0) }
            if drawable { expected.append(id) }

            if valuePresent(object, "model") {
                // The upstream 3D runtime is retained, but the helper has not yet audited every
                // mesh/material/rig pipeline. Never classify a mere model plan as full coverage.
                auditComplete = false
                problem("unsupported.model_readiness_audit", "3D mesh/rig strict readiness is not yet audited", id: id)
            } else if let path = object["particle"] as? String {
                requireResource(path, id: id)
                if particles.contains(id) { accounted.insert(id) }
                else { problem("unsupported.particle_plan", "Authored particle node has no runtime plan", id: id, resource: path) }
            } else if drawable {
                guard let layer = layers[id], prepared.contains(id) else {
                    problem("unsupported.layer_plan", "Authored drawable has no prepared GPU layer", id: id)
                    continue
                }
                accounted.insert(id)
                if let path = object["image"] as? String {
                    requireResource(path, id: id)
                    if !layer.sceneInput && layer.imageMaterial == nil {
                        fallbacks.insert(id)
                        problem("unsupported.image_material", "Original image material plan was omitted", id: id, resource: path)
                    }
                    // TEXParser can decode an embedded MP4 to a poster image. Audit the original
                    // material independently, so that a silent poster is never accepted as a
                    // successfully prepared video merely because no runtime .video survived.
                    if let materialPath = layer.imageMaterial?.materialPath,
                       let bytes = safeData(materialPath),
                       let material = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                       let passes = material["passes"] as? [[String: Any]],
                       let texture = (passes.first?["textures"] as? [Any])?.first as? String {
                        let header = ParticleMaterialPlanBuilder.textureHeader(named: texture,
                            materialPath: materialPath, readFile: safeData)
                        let embeddedVideo = header.flatMap { TEXParser(data: $0).extractVideoData() } != nil
                        let namedVideo = ["mp4", "mov", "m4v", "webm"].contains((texture as NSString).pathExtension.lowercased())
                        if embeddedVideo || namedVideo {
                            if case .video = layer.source {} else {
                                videosReady = false; fallbacks.insert(id)
                                problem("missing.required_video_runtime", "Original video texture was replaced by a still source", id: id, resource: texture)
                            }
                        }
                    }
                }
                // A shape quad's original effect generates its pixels; it has no authored image
                // material. A text layer uses the original font rasterizer, not an image substitute.
                if let authoredEffects = object["effects"] as? [[String: Any]] {
                    let expectedPaths = authoredEffects.compactMap { $0["file"] as? String }
                    if expectedPaths.count != authoredEffects.count || expectedPaths != layer.weEffects.map(\.file) {
                        problem("unsupported.effect_plan", "Authored effect order/count/path differs from planned effects", id: id)
                    }
                    for path in expectedPaths { requireResource(path, id: id) }
                    for effect in layer.weEffects {
                        if effect.passes.isEmpty {
                            problem("unsupported.effect_passes", "Original effect has no executable passes", id: id, resource: effect.file)
                        }
                    }
                }
            } else if valuePresent(object, "sound") {
                // A sound object is fully audited. Only a file genuinely absent from the original
                // package/VFS is a missing resource; a file that exists but could not be decoded or
                // prepared stays a specific audio runtime failure and is never misreported missing.
                let authored = authoredSoundFiles(object)
                let preparedSound = sounds[number.intValue]
                let preparedFiles = preparedSound?.files ?? []
                func normalized(_ path: String) -> String { path.replacingOccurrences(of: "\\", with: "/") }
                let preparedPaths = Set(preparedFiles.map { normalized($0.path) })
                let playbackReady = preparedSound.map { renderer.sounds.playback(of: $0.id)?.durations.count == authored.count } ?? false
                let decodedFilesReady = preparedPaths == Set(authored)
                    && preparedFiles.count == authored.count
                    && preparedFiles.allSatisfy { $0.duration > 0 && $0.channels > 0 }
                if !authored.isEmpty, let preparedSound, decodedFilesReady,
                   renderer.sounds.ids.contains(preparedSound.id), playbackReady {
                    auditedSounds.append(id)
                    for path in authored { requireResource(path, id: id) }
                } else {
                    auditComplete = false
                    if authored.isEmpty {
                        // A malformed/empty top-level `sound` declaration is an unsupported plan,
                        // not a missing resource: there is no concrete file to download or repair.
                        problem("unsupported.sound_plan", "Authored sound object declares no sound files (top-level sound must be a string or an array of strings)", id: id)
                    } else {
                        for path in authored {
                            let data = safeData(path)
                            let present = data != nil
                                || (AssetPathResolver.sanitize(path) == path && readOriginalResource(path) != nil)
                            if !present {
                                missing.insert(path)
                                problem("missing.audio_file", "Authored sound file is absent from the original package/VFS",
                                        id: id, resource: path)
                            } else if data == nil {
                                problem("runtime.audio_resource_unavailable",
                                        "Authored sound file exists in the original package/VFS but cannot be loaded within the resource limits",
                                        id: id, resource: path)
                            } else if !preparedPaths.contains(path) {
                                problem("runtime.audio_decode_failed",
                                        "Authored sound file exists in the original package/VFS but produced no decoded audio",
                                        id: id, resource: path)
                            } else if let file = preparedFiles.first(where: { normalized($0.path) == path }),
                                      !(file.duration > 0 && file.channels > 0) {
                                problem("runtime.audio_prepare_failed",
                                        "Decoded sound file has an invalid duration or channel count",
                                        id: id, resource: path)
                            }
                        }
                        if preparedPaths == Set(authored), preparedFiles.count != authored.count {
                            problem("runtime.audio_prepare_failed",
                                    "Prepared audio layer file count differs from the authored list", id: id)
                        } else if !preparedPaths.isSubset(of: Set(authored)) {
                            problem("runtime.audio_prepare_failed",
                                    "Prepared audio layer contains files not declared by the object", id: id)
                        } else if decodedFilesReady {
                            problem("runtime.audio_playback_missing",
                                    "Decoded sound files have no prepared renderer playback layer", id: id)
                        }
                    }
                }
            } else if ["light", "camera"].contains(where: { valuePresent(object, $0) }) {
                // Light/camera are not audited yet; they keep failing closed instead of being
                // silently approved.
                auditComplete = false
                problem("unsupported.nonplanar_readiness_audit", "Light/camera object readiness is not yet fully audited", id: id)
            } else {
                // Transform-only/group objects are accounted for by the exact original transform
                // hierarchy and object identity list, rather than being invented drawables.
                let knownGroupKeys: Set<String> = ["id", "parent", "name", "origin", "scale", "angles", "visible",
                    "disablepropagation", "attachment", "dependencies", "parallaxDepth", "sortorder", "type"]
                let type = object["type"] as? String
                if !Set(object.keys).isSubset(of: knownGroupKeys) || (type != nil && type != "group")
                    || !content.objectIDs.contains(number.intValue) {
                    auditComplete = false
                    problem("unsupported.object_kind", "Unclassified authored object cannot be silently discarded", id: id)
                }
            }

            if let fontPath = object["font"] as? String {
                guard let bytes = safeData(fontPath), let provider = CGDataProvider(data: bytes as CFData),
                      let originalFont = CGFont(provider), let originalName = originalFont.postScriptName as String?,
                      let actualFont = SceneFontRegistry.font(named: fontPath, size: 32),
                      actualFont.fontName == originalName else {
                    exactFonts = false; missing.insert(fontPath)
                    problem("missing.exact_font", "Exact original font could not be resolved; fallback is forbidden", id: id, resource: fontPath)
                    continue
                }
            }
        }

        if content.layers.count != renderer.layers.count {
            problem("unsupported.prepared_layer_coverage", "Not every loaded layer reached GPU preparation")
        }
        if renderer.particleSystemCount != content.particleSystems.count
            || (!content.particleSystems.isEmpty && renderer.particleSimulator == nil) {
            problem("unsupported.particle_simulation", "Original particle runtime/simulator coverage is incomplete")
        }
        for system in content.particleSystems {
            guard let plan = system.material, !plan.stages.isEmpty else {
                fallbacks.insert(system.objectID ?? "particle:<child>")
                problem("unsupported.particle_material", "Original particle shader plan was omitted", id: system.objectID)
                continue
            }
            // These are alternative geometry/expanded paths, not mandatory sequential passes.
            // The real renderer must use an original path and never its built-in approximation.
            if let materialRenderer = renderer.particleMaterials {
                let failures = plan.stages.compactMap {
                    materialRenderer.pipelineFailure($0, plan: plan, pixelFormat: renderer.lastSceneTarget?.pixelFormat ?? .rgba8Unorm)
                }
                if failures.count == plan.stages.count {
                    pipelineFailures += 1
                    problem("unsupported.particle_pipeline", failures.joined(separator: "; "), id: system.objectID, resource: plan.materialPath)
                }
            } else {
                pipelineFailures += 1
                problem("unsupported.particle_material_renderer", "Original particle material renderer is unavailable", id: system.objectID)
            }
        }
        for system in renderer.particleSystems where system.simulation == nil {
            guard let gpu = system.gpu, gpu.isReady, !gpu.reportedFailure else {
                problem("unsupported.particle_gpu_state", "Particle system never acquired a valid original GPU simulation", id: system.configuration.objectID)
                continue
            }
        }

        if let baseline = steadyBaseline {
            for (id, count) in renderer.imageMaterialFallbacks where count > (baseline.imageFallbacks[id] ?? 0) {
                fallbacks.insert(id)
                problem("unsupported.image_material_fallback", "Steady frame used a built-in image draw instead of its original material", id: id)
            }
            if (renderer.particleMaterials?.fallbacksReported ?? 0) > baseline.particleFallbacks
                || (renderer.particleMaterials?.fallbacksReported ?? 0) > 0 {
                fallbacks.insert("particle:<original-material>")
                problem("unsupported.particle_builtin_fallback", "Particle shader rendering fell back to built-in drawing")
            }
        } else {
            auditComplete = false
            problem("unsupported.steady_evidence_missing", "A post-warmup material fallback baseline was not supplied")
        }
        if renderer.hasPendingEffectPipelines || renderer.pendingTextRasters > 0 || renderer.pendingReplacements > 0 {
            problem("missing.pending_gpu_work", "Required original effect/text/layer preparation has not finished")
        }
        if content.bloom.enabled && content.bloomChain == nil && content.hdrChain == nil {
            problem("unsupported.original_bloom", "Authored bloom has no original engine pass chain")
        }
        for entry in renderer.layers {
            if case .video(let stream) = entry.layer.source {
                if stream.currentTexture() == nil || !stream.currentSeconds.isFinite || !stream.player.isMuted {
                    videosReady = false
                    problem("missing.video_frame", "Required original video stream has no valid muted decoded frame", id: entry.layer.id)
                }
            }
        }

        var scriptErrors = scriptConsoleErrors.map { SceneBackendDiagnostic(code: "unsupported.script_runtime", resource: nil, message: $0) }
        if let scripts = content.scripts {
            let sites = SceneScriptSiteBuilder(wallpaperID: scripts.wallpaperID).sites(in: scripts.document)
            if !sites.isEmpty && renderer.scripts.wallpaper == nil {
                scriptErrors.append(.init(code: "unsupported.script_start", resource: nil, message: "Original script attachment sites exist but runtime did not start"))
            }
        }
        if renderer.scripts.state.halted {
            scriptErrors.append(.init(code: "unsupported.script_halted", resource: nil, message: "Original SceneScript runtime halted"))
        }

        // Loader omissions may otherwise leave a plausible poster/layer while returning hasContent.
        // Preserve every upstream error unless it is an explicitly unused alternate particle path;
        // actual particle readiness/fallback is independently checked above.
        for message in SceneBackendRuntimeContext.current?.errorSnapshot() ?? [] {
            let alternateParticleWarning = message.hasPrefix("Particle material ")
                && (message.contains(": geometry stage:") || message.contains(": vertex stage:"))
                && !content.particleSystems.isEmpty
                && (renderer.particleMaterials?.fallbacksReported ?? 0) == 0
            if !alternateParticleWarning { problem("unsupported.upstream_runtime", message) }
        }
        let gpuComplete = renderer.lastCommandBuffer?.status == .completed && renderer.hasCompleteFrame && renderer.sharedFrame != nil
        if !gpuComplete { problem("missing.completed_gpu_frame", "A complete successfully executed Scene GPU frame is required") }
        if pipelineFailures > 0 { problem("unsupported.effect_pipeline", "Original shader pipeline failure count: \(pipelineFailures)") }
        return SceneBackendReadiness(sessionID: configuration.sessionID, generation: configuration.generation,
            projectDigest: roots.projectDigest, assetsManifestDigest: roots.assetsManifestDigest,
            authoredDrawableIDs: expected.sorted(), accountedDrawableIDs: accounted.sorted(),
            fallbackDrawableIDs: fallbacks.sorted(), unresolvedResources: missing.sorted(),
            scriptErrors: scriptErrors, pipelineFailureCount: pipelineFailures,
            exactFontsResolved: exactFonts, requiredVideoStreamsReady: videosReady,
            auditedSoundObjectIDs: auditedSounds.sorted(),
            gpuFrameCompleted: gpuComplete, capabilityAuditCompleted: auditComplete,
            diagnostics: diagnostics)
    }
}
