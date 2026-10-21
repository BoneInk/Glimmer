import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    /// Applies what scripts changed in the scene's structure: builds the layers `createLayer` made
    /// (off the main thread, through the loader; drawn once ready), drops destroyed ones (their GPU
    /// state freed after the in-flight frame) and queues `emitParticles` counts.
    func applyScriptEvents(_ events: [SceneScriptRenderEvent]) {
        var removed: [String] = []
        for event in events {
            switch event {
            case .create(let id, let object):
                timelines.addObject(object, id: id)
                buildScriptLayer(String(id), object: object)
            case let .setParent(id, parentID, attachment):
                let key = String(id)
                scriptParents[key] = (parentID.map(String.init), attachment)
                reparent(key, to: parentID.map(String.init), attachment: attachment)
            case .destroy(let id):
                let key = String(id)
                scriptParents.removeValue(forKey: key)
                let createdParticles = scriptParticles.removeValue(forKey: key)
                let createdSound = scriptSounds.removeValue(forKey: id)
                let createdModel = scriptModels.removeValue(forKey: key)
                _ = scripts.wallpaper?.takePrepared(id)
                if scriptLayers.removeValue(forKey: key) == nil, createdParticles == nil, createdSound == nil, createdModel == nil {
                    destroyedScriptLayers.insert(key)
                }
                if createdModel != nil {
                    spatial.models.removeAll { $0.id == key }
                    spatial.transforms.remove(key)
                    objectMotions.removeValue(forKey: key)
                    models?.remove(key)
                    shadowPass?.remove(key)
                }
                layers.removeAll { $0.layer.id == key }
                textRasterScales.removeValue(forKey: key)
                if createdParticles != nil {
                    particleSystems.removeAll { particleObjectID($0) == key }
                    objectMotions.removeValue(forKey: key)
                }
                sounds.remove(id)
                timelines.removeObject(id)
                removed.append(key)
            case .emit(let id, let count):
                pendingEmits[String(id), default: 0] += count ?? 1
            case let .materialFunction(id, effect, name):
                let key = String(id)
                for entry in layers where entry.layer.id == key {
                    effectGraph?.executeFunction(named: name, effectIndex: effect, of: entry.layer.weEffects, layer: key)
                }
            case .sound(let id, let playback):
                if SceneBackendRuntimeContext.isActive {
                    SceneBackendRuntimeContext.current?.recordError("unsupported_script_audio")
                    continue
                }
                sounds.perform(playback, on: id)
            case .video(let id, let command):
                let key = String(id)
                for entry in layers where entry.layer.id == key {
                    if case let .video(stream) = entry.layer.source { stream.perform(command) }
                }
            case let .animation(site, time, flags, rate, frame):
                timelines.restore(site, time: time, flags: flags, rate: rate, seenAt: frame)
            case let .textureAnimation(id, control, frame):
                timelines.restoreTexture(control, object: id, seenAt: frame)
            case let .rig(id, command):
                performRigCommand(command, on: String(id))
            }
        }
        if !removed.isEmpty {
            // The last frame that drew these may still be on the GPU; free their effect targets
            // once it has finished (`releaseFinishedEffectState`).
            deferredReleases.enqueue(removed, after: lastCommandBuffer)
        }
    }

    /// Swaps in objects rebuilt after a structural user-property change (`SceneObjectReplacement`):
    /// their textures are uploaded and their particle systems made off the render thread, then
    /// their layers and systems replace the old ones between two frames. The old ones' effect,
    /// material and puppet state is released (targets go to the spare list, which later passes on
    /// the queue are ordered after), and the rest of the scene keeps running. Dropped when the
    /// content changed meanwhile: that content was built with the change.
    func replaceObjects(_ replacement: SceneObjectReplacement) {
        let generation = currentContentGeneration
        let content = replacement.content
        pendingReplacements += 1
        contentQueue.async { [weak self] in
            guard let self else { return }
            var prepared: [PreparedLayer] = []
            var systems: [ParticleSystemRuntime] = []
            var analysis: SceneLayerAnalysis?
            if self.isCurrentContentGeneration(generation) {
                prepared = content.layers.compactMap { layer in
                    guard let frames = self.makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
                    return PreparedLayer(frames: frames, layer: Self.droppingPixels(layer))
                }
                let runtimes: [ParticleSystemRuntime?] = content.particleSystems.map { system in
                    var system = system
                    guard let texture = self.particleTexture(from: system.source, spriteSheet: system.spriteSheet != nil) else { return nil }
                    let fallback = system.fallbackSource.flatMap { self.makeTextureFrames(from: $0)?.first?.texture }
                    Self.dropPixels(&system)
                    // Seeded by position in the scene, as the whole content's systems are.
                    let seed = UInt32(truncatingIfNeeded: system.order) &+ self.particleSeed &* 0x9E37_79B9
                    return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(seed),
                                                 fallbackTexture: fallback)
                }
                ParticleSystemRuntime.linkFamilies(runtimes)
                systems = ParticleSystemRuntime.addingRendererDraws(runtimes.compactMap { $0 })
                analysis = SceneLayerAnalysis.make(content: content)
            }
            // Thread boundary: content queue → render thread.
            self.performOnRenderThread { [weak self] in
                guard let self else { return }
                self.pendingReplacements -= 1
                guard self.isCurrentContentGeneration(generation), let analysis else { return }
                self.install(replacement.objectIDs, layers: prepared, systems: systems, motions: content.motions,
                             analysis: analysis)
            }
        }
    }

    private func install(_ ids: Set<String>, layers prepared: [PreparedLayer], systems: [ParticleSystemRuntime],
                         motions: [String: SceneObjectMotion], analysis: SceneLayerAnalysis) {
        layers.removeAll { ids.contains($0.layer.id) }
        particleSystems.removeAll { particleObjectID($0).map(ids.contains) ?? false }
        for id in ids {
            effectGraph?.releaseLayer(id)
            imageMaterials?.releaseLayer(id)
            puppets?.releaseLayer(id)
            spriteFrameInputs.releaseLayer(id)
            puppetAlbedos.removeValue(forKey: id)
            puppetAnimators.removeValue(forKey: id)
            puppetWarps.removeValue(forKey: id)
            puppetCanvases.removeValue(forKey: id)
            textRasterScales.removeValue(forKey: id)
            lastTextSizes.removeValue(forKey: id)
            baseValueCaches.removeValue(forKey: id)
            if let motion = motions[id] { objectMotions[id] = motion }
        }
        textFrameCache.removeAll()
        particleSystems += systems
        layers += prepared
        for entry in prepared { registerTextureAnimation(entry) }
        layerAnalysis = layerAnalysis?.replacing(ids, with: analysis) ?? analysis
        bindingRevisions.bump(Set(ids.compactMap { Int($0).map(UserPropertyBindingOwner.object) }))
        refreshParticleRevisions()
        orderLayers()
        framePacing.wake(.interactive, at: wallTime())
    }

    // MARK: - Timelines

    /// An animated texture's layer shares its texture's clock (§2.7), frame times in sheet order.
    private func registerTextureAnimation(_ entry: PreparedLayer) {
        guard let animation = Self.textureAnimation(entry) else { return }
        timelines.registerTexture(object: animation.id, texture: animation.texture, frameTimes: animation.frameTimes)
    }

    static func textureAnimation(_ entry: PreparedLayer) -> (id: Int, texture: String, frameTimes: [Float])? {
        guard let key = entry.layer.textureKey, let id = Int(entry.layer.id) else { return nil }
        return (id, key, entry.frames.map(\.duration))
    }

    /// Builds an object a script created through the loader, off the main thread: a layer, a
    /// particle system (with its children) or a sound.
    private func buildScriptLayer(_ id: String, object: [String: SceneJSON]) {
        var visible = true
        if case .bool(let flag)? = object["visible"] { visible = flag }
        // Built on the script thread already: drawn in this frame, as WE's createLayer is.
        if let key = Int(id), let built = scripts.wallpaper?.takePrepared(key) as? PreparedScriptObject {
            destroyedScriptLayers.remove(id)
            installScriptObject(built, id: id, visible: visible)
            return
        }
        guard let makeLayer = scripts.makeLayer else { return }
        let generation = currentContentGeneration
        let wallpaper = scripts.wallpaper
        pendingScriptLayers += 1
        contentQueue.async { [weak self] in
            guard let self else { return }
            let built: PreparedScriptObject? = {
                guard self.isCurrentContentGeneration(generation) else { return nil }
                guard let created = makeLayer(object) else {
                    OWELog.error(.script, "createLayer: object \(id) can't be built")
                    return nil
                }
                return self.prepare(created, id: id)
            }()
            // Thread boundary: content queue → render thread.
            self.performOnRenderThread { [weak self] in
                guard let self else { return }
                self.pendingScriptLayers -= 1
                guard let built, self.isCurrentContentGeneration(generation), self.scripts.wallpaper === wallpaper else { return }
                guard self.destroyedScriptLayers.remove(id) == nil else { return }
                self.installScriptObject(built, id: id, visible: visible)
            }
        }
    }

    /// Starts drawing a created object, in the scripts' order.
    private func installScriptObject(_ built: PreparedScriptObject, id: String, visible: Bool) {
        scripts.setBaseVisibility(visible, for: id)
        switch built {
        case .layer(let entry):
            scriptLayers[id] = (entry, visible)
            layers.append(entry)
            registerTextureAnimation(entry)
        case .particles(let systems, let motion):
            scriptParticles[id] = (systems, motion)
            objectMotions[id] = motion
            particleSystems.append(contentsOf: systems)
        case .sound(let content):
            guard !SceneBackendRuntimeContext.isActive else {
                SceneBackendRuntimeContext.current?.recordError("unsupported_dynamic_sound")
                return
            }
            scriptSounds[content.id] = content
            sounds.add(content)
        case let .model(model, node, motion):
            scriptModels[id] = (model, node, motion)
            addScriptModel(id, (model, node, motion))
        }
        orderLayers()
    }

    /// A created object with its textures loaded (off the main thread).
    enum PreparedScriptObject {
        case layer(PreparedLayer)
        case particles([ParticleSystemRuntime], motion: SceneObjectMotion)
        case sound(SceneSoundContent)
        case model(SceneModelObject, node: SceneTransformHierarchy3D.Node, motion: SceneObjectMotion)
    }

    func prepare(_ created: SceneScriptCreatedObject, id: String) -> PreparedScriptObject? {
        switch created {
        case .layer(var layer):
            layer.order = Int.max
            guard let frames = makeTextureFrames(from: layer.source), !frames.isEmpty else { return nil }
            return .layer(PreparedLayer(frames: frames, layer: Self.droppingPixels(layer)))
        case .particles(let systems, let motion):
            // Above every authored object, like WE's createLayer; the scripts' order places it.
            let runtimes: [ParticleSystemRuntime?] = systems.enumerated().map { index, system in
                var system = system
                system.order = Int(Int32.max)
                guard let texture = particleTexture(from: system.source, spriteSheet: system.spriteSheet != nil) else { return nil }
                let fallback = system.fallbackSource.flatMap { makeTextureFrames(from: $0)?.first?.texture }
                Self.dropPixels(&system)
                let seed = UInt32(truncatingIfNeeded: (Int(id) ?? 0) &* 31 &+ index)
                return ParticleSystemRuntime(texture: texture, configuration: system, seed: ParticleRandom.pcg(seed),
                                             fallbackTexture: fallback)
            }
            ParticleSystemRuntime.linkFamilies(runtimes)
            let prepared = ParticleSystemRuntime.addingRendererDraws(runtimes.compactMap { $0 })
            return prepared.isEmpty ? nil : .particles(prepared, motion: motion)
        case .sound(let content):
            return .sound(content)
        case let .model(model, node, motion):
            var model = model
            model.id = id
            _ = model.plan?.upload(device: device)
            return .model(model, node: node, motion: motion)
        }
    }

    /// A model a script created, drawn from now on like the scene's own (after them, as WE's
    /// createLayer appends).
    func addScriptModel(_ id: String, _ created: ScriptModel) {
        spatial.models.removeAll { $0.id == id }
        spatial.models.append(created.model)
        spatial.transforms.insert(id, node: created.node)
        if let parent = scriptParents[id] { spatial.transforms.setParent(id, to: parent.parent, attachment: parent.attachment) }
        objectMotions[id] = created.motion
        models?.add(created.model)
    }

    /// `ILayer.setParent` in every parent graph the renderer composes worlds with, and in the
    /// visibility chain (a hidden parent hides its children).
    func reparent(_ id: String, to parent: String?, attachment: String?) {
        transforms.setParent(id, to: parent, attachment: attachment)
        spatial.transforms.setParent(id, to: parent, attachment: attachment)
        cameraTransforms.setParent(id, to: parent, attachment: attachment)
        cameraRig.setParent(id, to: parent, attachment: attachment)
        scripts.setParent(parent, for: id)
        // The analysis worked out lineages and bounds under the old parents; without this, idle
        // skipping could keep the old pose on screen.
        if let analysis = layerAnalysis?.reparented(nodes: transforms.nodes, motions: objectMotions) {
            layerAnalysis = analysis
            if audioCaptureLease == nil, Self.needsAudio(analysis, particles: particleSystems.map(\.configuration)) {
                audioCaptureLease = WallpaperServices.shared.acquireAudioCapture()
            }
        }
    }

    /// Puts `layers` in draw order (the scene's, or the one scripts set) with each layer's
    /// particle barrier.
    func orderLayers() {
        // A renderer after a system's first sits where the system does.
        let systems = particleSystems.filter { $0.simulation == nil }.map { system -> (id: String?, order: Int) in
            let order = system.configuration.order
            if order >= 0 && order < objectIDs.count { return (String(objectIDs[order]), order) }
            return (particleObjectID(system), order)
        }
        let order = SceneRendererScripts.drawOrder(layers: layers.map { ($0.layer.id, $0.layer.order) },
                                                   systems: systems, scriptOrder: scripts.state.order)
        var ordered: [PreparedLayer] = []
        ordered.reserveCapacity(layers.count)
        for (index, position) in order.sequence.enumerated() {
            var entry = layers[position]
            entry.particleBarrier = order.barriers[index]
            ordered.append(entry)
        }
        layers = ordered
    }

    /// Frees the effect state of destroyed script layers whose last frame the GPU has finished.
    func releaseFinishedEffectState() {
        guard deferredReleases.count > 0 else { return }
        deferredReleases.drain(live: Set(layers.map(\.layer.id))) { id in
            effectGraph?.releaseLayer(id)
            imageMaterials?.releaseLayer(id)
            puppets?.releaseLayer(id)
            spriteFrameInputs.releaseLayer(id)
            puppetAlbedos.removeValue(forKey: id)
            puppetAnimators.removeValue(forKey: id)
            puppetWarps.removeValue(forKey: id)
            puppetCanvases.removeValue(forKey: id)
        }
    }

    /// WE's sound layers each frame, on the scene clock: the wallpaper gain's fade takes the
    /// frame's wall step, as WE's main loop fades the wallpaper volume (0x1401113f8…0x140111444);
    /// then the volumes scripts set, and the layers' timers, which take the objects' update step
    /// (0x1401891a0: the scene's step, rate and pause ease applied; the sound's update divides it
    /// by a render-context value its constructor sets to 1, 0x1401f4f93, 0x14017c81e [I: nothing
    /// else was seen to change it]).
    func updateSounds() {
        sounds.advanceFade(frameSeconds: clock.frame)
        guard !sounds.isEmpty else { return }
        for id in sounds.ids {
            if let volume = scripts.object(String(id))?.scalar(.volume) ?? timelines.object(String(id))?.volume {
                sounds.setVolume(volume, of: id)
            }
        }
        sounds.update(deltaTime: clock.delta)
    }

    /// A sound object's world position this frame (its world matrix's translation, parents,
    /// timelines and scripts included), where a `spatialization` sound plays from.
    func soundWorldPosition(_ id: Int) -> SIMD3<Float> {
        let translation = world3D(String(id), in: spatial.transforms).columns.3
        return SIMD3(translation.x, translation.y, translation.z)
    }

    /// Hands the scripts this frame: the clock, the display and cursor, and every object at this
    /// frame's time with the last drawn frame's transforms, text sizes and camera
    /// (docs/scenescript-plan.md §4.4). They run on their own thread; `finishFrame` waits for them.
    func submitScriptFrame(viewports: [SceneViewport],
                           cursor: (position: SIMD2<Float>, onDisplay: Bool), leftDown: Bool,
                           animationEvents: [SceneAnimationEvent]) {
        let drawableSize = viewports[0].drawableSize
        var input = SceneScriptFrameInput()
        input.deltaTime = clock.delta
        timelines.describe(into: &input, events: animationEvents)
        input.environment = SceneScriptEngineEnvironment(
            screenResolution: SIMD2(Double(drawableSize.x), Double(drawableSize.y)),
            canvasSize: SIMD2(Double(sceneSize.x), Double(sceneSize.y)), placement: placement,
            pixelsPerPoint: Double(drawablePixelsPerPoint), isScreensaver: rendersScreenSaver)
        input.environment.zoom = frameZoom
        input.environment.isRunningInEditor = runsInEditor
        input.input = SceneScriptInput(cursorScreenPosition: cursorScreenPixels(viewports),
                                       cursorLeftDown: leftDown)
        // The cursor tracks the drawn plane; scripts and their hit tests see WE's world under it.
        input.cursorScenePosition = frameZoom.worldPoint(drawn: cursor.position)
        input.shakeOffset = lastCameraMotion?.shake ?? .zero
        if let parallax = lastCameraMotion?.parallax {
            input.parallax = SceneScriptCursorFrame.Parallax(state: parallax.state, amount: parallax.amount)
        }
        describeCursorTargets(into: &input, cursor: cursor.position)
        for entry in layers {
            guard let id = Int(entry.layer.id) else { continue }
            let script = scripts.object(entry.layer.id)
            let base = baseValues(entry)
            let animation = timelines.object(entry.layer.id)
            let own = entry.motion.local(animation: animation, script: script, scriptValues: false)
            input.objects[id] = SceneScriptObjectFeedback(
                origin: own.origin, scale: own.scale, angle: own.angle,
                alpha: baseOpacity(entry, base: base),
                color: animation?.color ?? SIMD3(base.color.x, base.color.y, base.color.z),
                brightness: animation?.brightness ?? base.brightness,
                visible: scripts.baseVisible(entry.layer.id),
                size: lastTextSizes[entry.layer.id] ?? layerBaseSize(entry),
                world: worldTransform(entry), animated: animation?.fields ?? SceneScriptOwnedFields())
            if case let .video(stream) = entry.layer.source {
                input.objects[id]?.playing = stream.isPlaying
                input.objects[id]?.videoTime = stream.currentSeconds
            }
        }
        for (key, objectMotion) in objectMotions {
            guard let id = Int(key) else { continue }
            let animation = timelines.object(key)
            let own = objectMotion.local(animation: animation, script: scripts.object(key), scriptValues: false)
            input.objects[id] = SceneScriptObjectFeedback(
                origin: own.origin, scale: own.scale, angle: own.angle, alpha: nil, color: nil, brightness: nil,
                visible: scripts.baseVisible(key), size: nil,
                world: transforms.world(of: key, live: { [self] id in liveLocal(id) }, attachments: puppetAttachments.affine),
                animated: animation?.fields ?? SceneScriptOwnedFields(), playing: sounds.isPlaying(id))
        }
        for entry in layers where entry.layer.puppet != nil {
            guard let id = Int(entry.layer.id), let animator = puppetAnimators[entry.layer.id] else { continue }
            let world = ScenePuppetAttachments.matrix(worldTransform(entry))
            input.rigs[id] = SceneScriptRigFeedback(layers: animator.layerStates, locals: animator.locals,
                                                    worlds: animator.worlds.map { world * $0 }, ended: animator.takeEnded(),
                                                    blendShapeWeights: animator.blendShapeWeights, events: animator.takeEvents())
        }
        for key in models?.riggedObjectIDs ?? [] {
            guard let id = Int(key), let animator = models?.animator(for: key) else { continue }
            let world = world3D(key, in: spatial.transforms)
            input.rigs[id] = SceneScriptRigFeedback(layers: animator.layerStates, locals: animator.locals,
                                                    worlds: animator.worlds.map { world * $0 }, ended: animator.takeEnded(),
                                                    events: animator.takeEvents())
        }

        scripts.submit(input)
    }

    /// What the cursor pass tests beyond the object table (docs/scenescript-plan.md §4.8): every
    /// model's 3D world (WE's, unzoomed), and in a perspective scene the ray from the last drawn
    /// frame's eye through the cursor, its view direction and every layer's 3D world.
    private func describeCursorTargets(into input: inout SceneScriptFrameInput, cursor: SIMD2<Float>) {
        for model in spatial.models {
            guard let id = Int(model.id) else { continue }
            input.cursorWorlds[id] = world3D(model.id, in: spatial.transforms)
        }
        guard isPerspective, let camera = lastFrameCamera, sceneSize.x > 0, sceneSize.y > 0 else { return }
        input.cursorRay = SceneScriptCursorRay.perspective(eye: camera.eye, viewProjection: camera.viewProjection,
                                                            normalized: cursor / sceneSize)
        input.cursorViewForward = camera.forward
        for entry in layers {
            guard let id = Int(entry.layer.id) else { continue }
            input.cursorWorlds[id] = world3D(entry.layer.id, in: spatial.transforms)
        }
    }

    /// The cursor in display pixels from the top-left of the wallpaper's view on the display it is
    /// on (`input.cursorScreenPosition`); where it was last seen while it is on none of them.
    private func cursorScreenPixels(_ viewports: [SceneViewport]) -> SIMD2<Double> {
        if let fixedPointer, let drawable = viewports.first?.drawableSize {
            // The fixed pointer on the drawn scene, from the drawable's top-left.
            let point = ScenePlacementScale.drawablePoint(scenePoint: fixedPointer * sceneSize, placement: placement,
                                                          sceneSize: sceneSize, drawableSize: drawable,
                                                          pixelsPerPoint: viewports[0].pixelsPerPoint)
            return SIMD2(Double(point.x), Double(drawable.y - point.y))
        }
        guard let pixels = viewports.lazy.compactMap(\.cursorScreenPixels).first else { return lastCursorScreenPixels }
        lastCursorScreenPixels = pixels
        return pixels
    }
}
