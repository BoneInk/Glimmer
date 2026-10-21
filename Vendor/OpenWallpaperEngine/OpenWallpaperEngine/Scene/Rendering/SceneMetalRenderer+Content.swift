import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    func setContent(_ content: SceneMetalContent?) {
        clockLayerIDs = content?.scripts.map { SceneClockLayers.ids(in: $0.document) } ?? []
        stillLayerIDs = Set(content?.layers.filter { $0.text != nil }.map(\.id) ?? [])
            .union(content?.scripts.map { SceneClockLayers.stillIDs(in: $0.document) } ?? [])
        baseValueCaches.removeAll()
        effectAssetTextures.removeAll()
        clearUploadedImages()
        effectAssetFrames.removeAll()
        solidEffectInputs.removeAll()
        solidSceneBases.removeAll()
        mediaTextures = nil
        effectGraph?.releaseTargets()
        particleMaterials?.releaseAll()
        imageMaterials?.releaseAll()
        imageMaterialFallbacks.removeAll()
        puppets?.releaseAll()
        spriteFrameInputs.releaseAll()
        puppetAlbedos.removeAll()
        puppetAnimators.removeAll()
        emitterImages.reset()
        puppetWarps.removeAll()
        puppetCanvases.removeAll()
        contentGenerationLock.lock()
        contentGeneration &+= 1
        let generation = contentGeneration
        contentGenerationLock.unlock()

        guard let content else {
            layerAnalysis = nil
            audioCaptureLease = nil
            layers = []
            particleSystems = []
            objectMotions = [:]
            scripts.stop()
            timelines.clear()
            sounds.stopAll()
            scriptParticles.removeAll()
            scriptSounds.removeAll()
            scriptLayers.removeAll()
            scriptModels.removeAll()
            destroyedScriptLayers.removeAll()
            pendingEmits.removeAll()
            objectIDs = []
            hasContent = false
            hasCompleteFrame = false
            textFrameCache.removeAll()
            textRaster.reset()
            textRasterScales.removeAll()
            clock = SceneClock()
            transforms = .empty
            spatial = SceneSpatialContent()
            depthBuffer.releaseAll()
            planarReflection?.release()
            lastPointer = nil
            lastCameraMotion = nil
            lastFrameCamera = nil
            lastTextSizes.removeAll()
            cameraParallax = SceneCameraParallax(sceneSize: sceneSize)
            parallaxSettledPointer = nil
            cursorTracker = SceneCursorTracker()
            deferredReleases.removeAll()
            lastCommandBuffer = nil
            return
        }
        // Subscribed before the scripts start, so the artwork the session already has is there.
        let bindsSystemTexture = content.layers.contains { layer in
            layer.systemImage != nil
                || layer.weEffects.contains { $0.passes.contains { !$0.systemTextures.isEmpty } }
        }
        if bindsSystemTexture, let media = scripts.services?.media {
            mediaTextures = SceneMediaTextures(source: media, device: device)
        }
        contentQueue.async { [weak self] in
            guard let self, self.isCurrentContentGeneration(generation) else { return }
            // Each layer's upload is independent; built side by side, kept in layer order.
            var built = [[RenderTextureFrame]?](repeating: nil, count: content.layers.count)
            built.withUnsafeMutableBufferPointer { slots in
                let slots = slots
                DispatchQueue.concurrentPerform(iterations: content.layers.count) { index in
                    slots[index] = self.makeTextureFrames(from: content.layers[index].source)
                }
            }
            let preparedLayers: [PreparedLayer] = zip(built, content.layers).compactMap { frames, layer in
                guard let frames, !frames.isEmpty else { return nil }
                return PreparedLayer(frames: frames, layer: Self.droppingPixels(layer))
            }
            let imageLayers = Set(content.particleSystems.flatMap { $0.emitterImages.map(\.layerID) })
            let imageSources = Dictionary(preparedLayers.compactMap { entry -> (String, ParticleEmitterImagePoints.Source)? in
                guard imageLayers.contains(entry.layer.id), let frame = entry.frames.first else { return nil }
                let size = entry.layer.source.pixelSize
                let sampling = ParticleEmitterImagePoints.Sampling(texture: frame.texture, uvOrigin: frame.uvOrigin,
                                                                   uvAxisX: frame.uvAxisX, uvAxisY: frame.uvAxisY)
                return (entry.layer.id, .init(sampling: sampling, imageSize: SIMD2(Int(size.x), Int(size.y)),
                                              rig: ParticleEmitterImageBones.Rig(entry.layer.puppet)))
            }, uniquingKeysWith: { first, _ in first })
            var imagePoints: [String: [SIMD4<Int32>]] = [:]
            let runtimes: [ParticleSystemRuntime?] = content.particleSystems.enumerated().map { index, system in
                var system = system
                ParticleEmitterImagePoints.fill(&system.emitterImages, sources: imageSources, device: self.device,
                                                queue: self.commandQueue, cache: &imagePoints)
                guard let texture = self.particleTexture(from: system.source, spriteSheet: system.spriteSheet != nil) else { return nil }
                let fallback = system.fallbackSource.flatMap { self.makeTextureFrames(from: $0)?.first?.texture }
                Self.dropPixels(&system)
                // Seeded by position in the scene, so a wallpaper's particles replay the same way.
                let seed = UInt32(index) &+ self.particleSeed &* 0x9E37_79B9
                return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(seed),
                                             fallbackTexture: fallback)
            }
            ParticleSystemRuntime.linkFamilies(runtimes)
            let preparedParticleSystems = ParticleSystemRuntime.addingRendererDraws(runtimes.compactMap { $0 })
            guard self.isCurrentContentGeneration(generation) else { return }
            // The models' meshes go to the GPU here, off the render thread, so the first frame
            // drawing them has nothing to upload.
            for model in content.spatial.models { _ = model.plan?.upload(device: self.device) }
            let analysis = SceneLayerAnalysis.make(content: content)
            // Thread boundary: content queue → render thread.
            self.performOnRenderThread { [weak self] in
                guard let self, self.isCurrentContentGeneration(generation) else { return }
                self.sceneSize = content.size
                self.sharedFrame = nil
                self.bloom = content.bloom
                self.lighting = content.lighting
                self.cameraRig = SceneCameraRigs.make(for: content)
                self.cameraTransforms = content.spatial.transforms
                self.spatial = content.spatial
                self.modelDrawing?.setContent(content.spatial.models, content: content)
                self.shadowPass?.setContent()
                self.planarReflection?.setContent()
                for stage in self.frameStages { stage.setContent(content) }
                self.postProcess.setContent(content)
                self.particleSystems = preparedParticleSystems
                self.layerAnalysis = analysis
                let needsAudio = Self.needsAudio(analysis, particles: preparedParticleSystems.map(\.configuration))
                if needsAudio != (self.audioCaptureLease != nil) {
                    self.audioCaptureLease = needsAudio ? WallpaperServices.shared.acquireAudioCapture() : nil
                }
                self.framePacing.changesOnItsOwn = FramePacing.changesOnItsOwn(
                    analysis, particles: !preparedParticleSystems.isEmpty, cameraShake: content.camera.shake)
                self.framePacing.wake(.interactive, at: self.wallTime())
                self.transforms = content.transforms
                self.objectMotions = content.motions
                self.objectIDs = content.objectIDs
                self.wallpaperKey = content.wallpaperKey
                self.camera = content.camera
                self.cameraGeneral = content.general
                self.clearColor = content.clearColor
                self.clearEnabled = content.clearEnabled
                self.keptSceneTargets = []
                self.cameraParallax = SceneCameraParallax(sceneSize: content.size, enabled: Self.parallaxEnabled(content.camera))
                self.parallaxSettledPointer = nil
                self.lastCameraMotion = nil
                self.lastFrameCamera = nil
                self.lastTextSizes.removeAll()
                self.textFrameCache.removeAll()
                self.textRaster.reset()
                self.textRasterScales.removeAll()
                let running = self.scripts.wallpaper
                self.scripts.setContent(content.scripts, visibility: content.visibility,
                                        parents: content.transforms.nodes.compactMapValues(\.parentID))
                self.userVisibility = content.userVisibility
                // A property changed while the content was being built shows in it at once.
                self.applyUserVisibility()
                self.timelines.setTimelines(content.timelines,
                                            restart: self.scripts.wallpaper != nil && self.scripts.wallpaper !== running)
                if self.scripts.wallpaper == nil || self.scripts.wallpaper !== running {
                    // New scripts: the old ones' layers are gone with them.
                    self.scriptLayers.removeAll()
                    self.destroyedScriptLayers.removeAll()
                    self.pendingEmits.removeAll()
                    self.scriptParticles.removeAll()
                    self.scriptSounds.removeAll()
                    self.scriptModels.removeAll()
                    self.scriptParents.removeAll()
                }
                for (id, created) in self.scriptModels { self.addScriptModel(id, created) }
                for (id, parent) in self.scriptParents { self.reparent(id, to: parent.parent, attachment: parent.attachment) }
                for (id, created) in self.scriptParticles {
                    self.particleSystems += created.systems
                    self.objectMotions[id] = created.motion
                }
                self.sounds.setContent(content.sounds + self.scriptSounds.keys.sorted().compactMap { self.scriptSounds[$0] })
                for (id, created) in self.scriptLayers { self.scripts.setBaseVisibility(created.visible, for: id) }
                self.layers = preparedLayers + self.scriptLayers.values.map(\.entry)
                self.timelines.registerTextures(self.layers.compactMap(Self.textureAnimation))
                self.orderLayers()
                self.hasContent = true
                self.hasCompleteFrame = false
                self.clock = SceneClock()
            }
        }
    }

    var currentContentGeneration: Int {
        contentGenerationLock.lock()
        defer { contentGenerationLock.unlock() }
        return contentGeneration
    }

    func isCurrentContentGeneration(_ generation: Int) -> Bool {
        contentGenerationLock.lock()
        defer { contentGenerationLock.unlock() }
        return contentGeneration == generation
    }

    func setPlacement(_ placement: WallpaperPlacement) {
        self.placement = placement
    }
}
