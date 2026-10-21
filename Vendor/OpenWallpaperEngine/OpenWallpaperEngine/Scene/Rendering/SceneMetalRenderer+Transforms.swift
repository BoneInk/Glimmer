import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    /// The scene's own `general.cameraparallax` (possibly user-bound, or set by a script) or the
    /// app's parallax toggle.
    var parallaxEnabled: Bool {
        if let scripted = scripts.state.scene.flag(.cameraparallax) { return scripted }
        return Self.parallaxEnabled(camera)
    }

    /// The scene's `general.cameraparallax` (as resolved) or the app's parallax toggle, before scripts.
    static func parallaxEnabled(_ camera: SceneCameraEffects) -> Bool {
        camera.parallax || WallpaperServices.shared.userPropertyString("_owe_effect_enabled_parallax") == "true"
    }

    /// WE's camera shake, then its parallax (`SceneCameraShake`, `SceneCameraParallax`), in the
    /// order its scene update runs them: the parallax target includes the shaken eye. Scripts'
    /// `thisScene.camerashake…`/`cameraparallax…` settings override the scene's.
    func cameraMotion(pointer: SIMD2<Float>, time: Float, deltaTime: Float) -> CameraMotion {
        let scene = scripts.state.scene
        let shaking = scene.flag(.camerashake) ?? camera.shake
        let shake: SIMD3<Float> = shaking
            ? SceneCameraShake.cameraOffset(time: time, speed: sceneSetting(.camerashakespeed) ?? camera.shakeSpeed,
                                            amplitude: sceneSetting(.camerashakeamplitude) ?? camera.shakeAmplitude,
                                            roughness: sceneSetting(.camerashakeroughness) ?? camera.shakeRoughness,
                                            orthographicHeight: camera.orthographic ? sceneSize.y : nil)
            : .zero
        var parallax: (state: SceneCameraParallax, amount: Float)?
        // Read every frame: turning parallax on or off eases in or out (`SceneCameraParallax.weight`).
        cameraParallax.ease(enabled: parallaxEnabled, deltaTime: deltaTime)
        if cameraParallax.isActive {
            let settles = fixedPointer != nil && fixedPointer != parallaxSettledPointer
            cameraParallax.update(cursor: pointer, eye: SIMD2(shake.x, shake.y), sceneSize: sceneSize,
                                  influence: sceneSetting(.cameraparallaxmouseinfluence) ?? camera.parallaxMouseInfluence,
                                  delay: settles ? 0 : sceneSetting(.cameraparallaxdelay) ?? camera.parallaxDelay,
                                  deltaTime: deltaTime)
            parallaxSettledPointer = fixedPointer
            // `_owe_effect_parallax_amount` is an app extra, 1 (WE's amount) by default.
            let amount = (sceneSetting(.cameraparallaxamount) ?? camera.parallaxAmount)
                * WallpaperServices.shared.userPropertyValue("_owe_effect_parallax_amount", fallback: 1)
            if camera.orthographic { parallax = (cameraParallax, amount) }
        }
        // WE moves the camera by the shake (0x140199580). A perspective scene's camera carries it;
        // an orthographic scene's layers are drawn without the camera, so they move the other way.
        guard camera.orthographic else {
            return CameraMotion(parallax: parallax, shake: .zero, cameraShake: shake,
                                audioLevel: WallpaperServices.shared.audioLevel)
        }
        return CameraMotion(parallax: parallax, shake: SIMD2(shake.x, shake.y),
                            audioLevel: WallpaperServices.shared.audioLevel)
    }

    /// A number of the scene's settings this frame: a script's, else its timeline's; nil leaves
    /// the authored (or user-bound) one.
    func sceneSetting(_ field: SceneScriptSceneField) -> Float? {
        scripts.state.scene.scalar(field) ?? timelines.sceneScalar(field)
    }

    /// What the camera rig needs this frame (`SceneCameraRigInput`): the camera layers' live
    /// visibility and transforms, the shake and the settings scripts and timelines set, and the
    /// default camera `thisScene.setCameraTransforms` set.
    func cameraRigInput(time: Double, motion: CameraMotion) -> SceneCameraRigInput {
        var input = SceneCameraRigInput(sceneSize: sceneSize, aspect: sceneSize.x / max(sceneSize.y, 1), time: time,
                                        deltaTime: Float(clock.delta))
        input.shake = motion.cameraShake
        input.isVisible = { [unowned self] id in scripts.object(id)?.flag(.visible) ?? scripts.baseVisible(id) }
        input.live = { [unowned self] id in
            // Only what scripts or timelines move differs from the authored transform the rig holds.
            let script = scripts.object(id), animation = timelines.object(id)
            guard script != nil || animation != nil, let authored = cameraTransforms.nodes[id]?.local,
                  let motion = objectMotions[id] ?? layers.first(where: { $0.layer.id == id })?.motion else { return nil }
            return motion.local3D(authored: authored, animation: animation, script: script)
        }
        input.layerFov = { [unowned self] id in scripts.object(id)?.scalar(.fov) }
        input.layerZoom = { [unowned self] id in scripts.object(id)?.scalar(.zoom) }
        input.fov = sceneSetting(.fov)
        input.nearZ = sceneSetting(.nearz)
        input.farZ = sceneSetting(.farz)
        input.cameraFade = scripts.state.scene.flag(.camerafade)
        input.scriptCamera = scripts.state.scene.scriptCamera
        return input
    }

    /// The parallax offset of a layer: its root object's live origin and `parallaxDepth`.
    func parallaxOffset(_ entry: PreparedLayer, local: SceneLocalTransform,
                        motion: CameraMotion) -> SIMD2<Float> {
        guard let parallax = motion.parallax else { return .zero }
        let rootID = transforms.root(of: entry.layer.id)
        if rootID == entry.layer.id {
            let depth = entry.layer.parallaxDepth
            let scripted = scripts.object(rootID)?.vector2(.parallaxDepth) ?? timelines.object(rootID)?.parallaxDepth
            return parallax.state.offset(rootOrigin: local.origin, rootDepth: scripted ?? SIMD2(depth.x, depth.y),
                                         amount: parallax.amount)
        }
        guard let node = transforms.nodes[rootID] else { return .zero }
        let rootLocal = liveLocal(rootID) ?? node.local
        return parallax.state.offset(rootOrigin: rootLocal.origin, rootDepth: parallaxDepth(of: rootID, node: node),
                                     amount: parallax.amount)
    }

    /// A root object's `parallaxDepth`: a script's, else its timeline's, else authored.
    private func parallaxDepth(of id: String, node: SceneTransformHierarchy.Node) -> SIMD2<Float> {
        scripts.object(id)?.vector2(.parallaxDepth) ?? timelines.object(id)?.parallaxDepth ?? node.parallaxDepth
    }

    /// A visible layer's opacity, colour and placed quad this frame: what scripts wrote, then the
    /// timeline, then authored (moved by user bindings).
    func layerDraw(_ entry: PreparedLayer, baseSize: SIMD2<Float>,
                   motion: CameraMotion, contentOffset: SIMD2<Float> = .zero) -> LayerDraw {
        let base = baseValues(entry)
        let script = scripts.object(entry.layer.id)
        var opacity = script?.scalar(.alpha) ?? baseOpacity(entry, base: base)
        if entry.layer.text != nil {
            opacity *= WallpaperServices.shared.userPropertyValue("_owe_text_\(entry.layer.id)_opacity", fallback: 1)
        }
        var local = evaluatedLocal(entry)
        let own = local
        let parallaxOffset = parallaxOffset(entry, local: local, motion: motion)
        let musicSyncLevel = entry.layer.musicSync?.levelSource.map { $0() } ?? motion.audioLevel
        local.scale *= 1 + (entry.layer.musicSync?.zoomAmount ?? 0) * Float(musicSyncLevel)
        local.angle += entry.layer.musicSync.map { $0.tiltAmount * Float(musicSyncLevel) * .pi / 180 } ?? 0
        // A fullscreen layer is drawn in screen space (`passthrough` without `TRANSFORM`), which
        // the orthographic zoom doesn't scale.
        let view = entry.layer.fillsScene ? SceneAffineTransform.identity : frameZoom.plane
        let world = worldTransform(entry, local: local)
        let quad = SceneQuadGeometry(world: view * world, size: baseSize, alignment: alignment(entry))
        // WE draws a layer where its transform and the camera put it; an oversized layer (sized
        // to hide its edges while it moves) isn't pinned inside the scene.
        let center = quad.center + view.linear * (parallaxOffset - motion.shake)
            + quad.axisX * (contentOffset.x / max(baseSize.x, .leastNormalMagnitude))
            + quad.axisY * (contentOffset.y / max(baseSize.y, .leastNormalMagnitude))
        let animation = timelines.object(entry.layer.id)
        let rgb = script?.vector3(.color) ?? animation?.color
        let color = rgb.map { SIMD4<Float>($0.x, $0.y, $0.z, base.color.w) } ?? base.color
        let brightness = renderSettings.appliesBrightness
            ? script?.scalar(.brightness) ?? animation?.brightness ?? base.brightness : 1
        drawProbe?.record(layer: entry.layer.id, .init(opacity: opacity, color: color, brightness: brightness, local: own))
        return LayerDraw(opacity: opacity, color: color, brightness: brightness,
                         quad: SceneQuadGeometry(center: center, axisX: quad.axisX, axisY: quad.axisY),
                         musicSyncLevel: musicSyncLevel, world: world)
    }

    /// A layer's opacity before scripts: its timeline's value this frame, else authored or user-bound.
    func baseOpacity(_ entry: PreparedLayer, base: SceneLayerBaseValues) -> Float {
        timelines.object(entry.layer.id)?.alpha ?? base.opacity
    }

    /// The layer's unscaled size this frame: a script bound to `size` (WE's image property is
    /// writable and drawn every frame, wallpaper64.exe 0x1401e8bb0), else its timeline, else authored.
    func layerBaseSize(_ entry: PreparedLayer) -> SIMD2<Float> {
        scripts.object(entry.layer.id)?.vector2(.size) ?? timelines.object(entry.layer.id)?.size ?? entry.layer.size
    }

    /// A text layer's current string (a script's, else authored), laid out and rasterised (through
    /// the text cache) at `pixelsPerUnit`, with the block size the layout settled on.
    func layerTextFrame(_ entry: PreparedLayer, boxSize: SIMD2<Float>,
                        pixelsPerUnit: Float) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>) {
        guard let authored = entry.layer.text else { return (textureFrame(for: entry), boxSize) }
        let scripted = scripts.text(authored, of: entry.layer.id)
        var text = scripted.text
        // Without effects the box is its own quad under the glyphs (`encodeTextBackground`).
        if text.opaqueBackground, entry.layer.weEffects.isEmpty { text.drawsBackgroundSeparately = true }
        return makeTextFrame(text, value: scripted.value, pointSize: scripted.pointSize, boxSize: boxSize,
                             pixelsPerUnit: pixelsPerUnit, layerID: entry.layer.id,
                             fill: !scripted.text.rastersInColor && entry.layer.weEffects.isEmpty ? nil : textFill(entry))
            ?? (textureFrame(for: entry), boxSize)
    }

    /// Whether a text layer's raster this frame holds its colours (font effects or a background
    /// box, authored or scripted: `SceneMetalText.rastersInColor`); false for other layers.
    func textRastersInColor(_ entry: PreparedLayer) -> Bool {
        guard let authored = entry.layer.text else { return false }
        return scripts.text(authored, of: entry.layer.id).text.rastersInColor
    }

    /// A text layer's colour this frame (a script's, else its timeline's, else authored, with the
    /// user's text colour), which text with font effects rasterises with (`SceneTextEffects`).
    func textFill(_ entry: PreparedLayer) -> SIMD3<Float> {
        let base = baseValues(entry).color
        let color = scripts.object(entry.layer.id)?.vector3(.color) ?? timelines.object(entry.layer.id)?.color
            ?? SIMD3(base.x, base.y, base.z)
        return color * textTint(layerID: entry.layer.id)
    }

    // MARK: - Transforms

    func beginTransformFrame() {
        frameLocals.removeAll(keepingCapacity: true)
        frameLocals3D.removeAll(keepingCapacity: true)
        layerIndexByStateId.removeAll(keepingCapacity: true)
        for (index, entry) in layers.enumerated() { layerIndexByStateId[entry.layer.id] = index }
        frameZoom = orthographicZoom()
        // Nested tilts compose in depth from this frame's angles, scripts' and timelines' included
        // (docs/models-plan.md §5.16); a perspective scene draws through its 3D hierarchy anyway.
        if !isPerspective { transforms.updateComposition { [unowned self] id in self.liveLocal(id) } }
    }

    /// A layer's authored values moved by its user bindings: the base that animations and scripts
    /// start from. Kept per binding revision (`SceneBindingRevisions`) unless a bound property
    /// follows the music.
    func baseValues(_ entry: PreparedLayer) -> SceneLayerBaseValues {
        let values = boundBaseValues(entry)
        return editorLive.isEmpty ? values : editorLive.base(values, id: entry.layer.id)
    }

    private func boundBaseValues(_ entry: PreparedLayer) -> SceneLayerBaseValues {
        let bindings = entry.layer.bindings
        guard !bindings.isEmpty else { return SceneLayerBaseValues(entry.layer) }
        let context = LiveSceneValueContext()
        if bindings.properties.contains(where: context.isMusicSynced) {
            return bindings.baseValues(for: entry.layer, in: context)
        }
        let id = entry.layer.id
        let revision = bindingRevisions.revision(of: id)
        var cache = baseValueCaches[id] ?? SceneBindingCache()
        let reused = cache.revision == revision
        let values = cache.value(at: revision) { bindings.baseValues(for: entry.layer, in: context) }
        if reused { bindingRevisions.noteReuse(of: id, cachedAt: cache.revision ?? revision) } else { baseValueCaches[id] = cache }
        return values
    }

    /// Hands every particle system its object's binding revision, which its kept overrides key on.
    func refreshParticleRevisions() {
        for system in particleSystems {
            system.bindingRevision = particleObjectID(system).map(bindingRevisions.revision(of:)) ?? 0
        }
    }

    /// The value context of object `id`'s draw this frame: the timelines' values at its binding revision.
    func values(of id: String) -> LiveSceneValueContext {
        var values = timelines.values
        values.bindingRevision = bindingRevisions.revision(of: id)
        return values
    }

    func evaluatedLocal(_ entry: PreparedLayer) -> SceneLocalTransform {
        objectLocal(entry.motion, id: entry.layer.id)
    }

    /// An object's own transform this frame (`SceneObjectMotion.local`, scripts' values
    /// included), evaluated once per frame.
    func objectLocal(_ motion: SceneObjectMotion, id: String) -> SceneLocalTransform {
        if let cached = frameLocals[id] { return cached }
        var local = motion.local(animation: timelines.object(id), script: scripts.object(id))
        if !editorLive.isEmpty { local = editorLive.local(local, id: id) }
        frameLocals[id] = local
        return local
    }

    /// This frame's own transform of any object: a drawn layer's, or another object's (groups,
    /// particle systems) from its motion. Nil for an object without either.
    func liveLocal(_ id: String) -> SceneLocalTransform? {
        if let index = layerIndexByStateId[id] { return evaluatedLocal(layers[index]) }
        return objectMotions[id].map { objectLocal($0, id: id) }
    }

    /// A layer's world this frame: its own transform (`local`, else its evaluated one) in its
    /// parents' space, then its attachment on its parent's rig (the witcher's sword, 3803167460,
    /// hangs from the hand, not the parent's origin). Every ancestor uses its live (scripted,
    /// animated) transform, so moving a parent moves its children. WE's world, without the
    /// orthographic zoom (`frameZoom`), which only the draw applies.
    func worldTransform(_ entry: PreparedLayer, local: SceneLocalTransform? = nil) -> SceneAffineTransform {
        transforms.world(of: entry.layer.id, local: local ?? evaluatedLocal(entry), live: { [self] id in liveLocal(id) },
                         attachments: puppetAttachments.affine)
    }

    /// This frame's orthographic zoom (`SceneOrthographicZoom`) until the camera rig gives the
    /// frame's own: `general.zoom` × the camera's zoom a script set, and the last frame's camera
    /// view. None in a perspective scene, where the zoom isn't read.
    private func orthographicZoom() -> SceneOrthographicZoom {
        guard !isPerspective else { return .none }
        let general = Float(spatial.camera.zoom)
        return SceneOrthographicZoom(factor: general * (scripts.state.scene.scriptCamera?.zoom ?? 1), sceneSize: sceneSize,
                                     view: frameZoom.view)
    }

    /// A particle system's emitter transform this frame: its object's, parents included, moved by
    /// camera parallax and shake as WE moves every object's model matrix (0x14018a0b3): the
    /// system's particles follow it unless it is `worldspace`; its children follow it through
    /// their links. The orthographic zoom (`frameZoom`) scales the plane they're drawn in.
    func emitterWorld(_ configuration: SceneMetalParticleSystem,
                      motion: CameraMotion) -> SceneAffineTransform? {
        guard let id = configuration.objectID else { return nil }
        var world = transforms.world(of: id, live: { [self] id in liveLocal(id) }, attachments: puppetAttachments.affine)
        world.translation += particleParallaxOffset(id, motion: motion) - motion.shake
        return frameZoom.plane * world
    }

    /// A `layerimage` emitter's layer this frame (`ParticleFrameInputs.placeImages`), moved by
    /// camera parallax and shake as an emitter is (`emitterWorld`); nil when no such object exists.
    /// A Puppet Warp layer's bones for the `layerimage` emitters on it (`SceneEmitterImages`).
    func emitterImageBones(_ id: String) -> ParticleLayerBones? {
        guard let index = layerIndexByStateId[id], let puppet = layers[index].layer.puppet else { return nil }
        return emitterImages.bones(of: id, puppet: puppet, animator: puppetAnimators[id])
    }

    /// Samples again `system`'s images that are due (flag 0x20000, `SceneEmitterImages.resample`).
    func resampleEmitterImages(_ system: ParticleSystemRuntime) {
        emitterImages.resample(system) { [self] id in
            guard let index = layerIndexByStateId[id] else { return nil }
            let entry = layers[index]
            return (entry.frames, entry.layer.puppet, entry.layer.source.pixelSize)
        }
    }

    func emitterImageLayerWorld(_ id: String, motion: CameraMotion) -> SceneAffineTransform? {
        guard transforms.nodes[id] != nil else { return nil }
        var world = transforms.world(of: id, live: { [self] id in liveLocal(id) }, attachments: puppetAttachments.affine)
        world.translation += particleParallaxOffset(id, motion: motion) - motion.shake
        return frameZoom.plane * world
    }

    /// The scene object a particle system belongs to: its own, or its family root's for a child.
    func particleObjectID(_ system: ParticleSystemRuntime) -> String? {
        var current: ParticleSystemRuntime? = system.simulation ?? system
        var steps = 0
        while let candidate = current, steps < 64 {
            if let id = candidate.configuration.objectID { return id }
            current = candidate.parent
            steps += 1
        }
        return nil
    }

    /// Systems below this many live particles keep drawing at full resolution: the pass split of a
    /// reduced-resolution draw costs more than it saves on a few sprites.
    static let reducedResolutionParticleMinimum = 256

    /// Whether `system` draws at half resolution this frame (`SceneRenderSettings.reducedResolutionParticles`):
    /// a large additive material system of a scene without depth, not reading the scene.
    func drawsReducedResolution(_ system: ParticleSystemRuntime) -> Bool {
        guard renderSettings.reducedResolutionParticles, frameDepth == nil,
              system.configuration.material?.blending.lowercased() == "additive",
              particleMaterials?.readsSceneSnapshot(system) == false else { return false }
        return (system.gpu?.completedCount ?? 0) >= Self.reducedResolutionParticleMinimum
    }

    /// Draws `systems` additively into a cleared half-resolution target, returned to be added onto
    /// the scene; `left` are the systems whose pipeline for it isn't ready (or all, without a target).
    func drawReducedResolution(_ systems: [ParticleSystemRuntime], scene: MTLTexture, commandBuffer: MTLCommandBuffer,
                               context: (ParticleSystemRuntime) -> ParticleMaterialRenderer.DrawContext)
        -> (target: MTLTexture?, left: [ParticleSystemRuntime]) {
        var avoiding = [scene]
        if let sceneCopy { avoiding.append(sceneCopy) }
        guard let particleMaterials,
              let target = renderTargetPool.texture(width: max(scene.width / 2, 1), height: max(scene.height / 2, 1),
                                                    pixelFormat: scene.pixelFormat, avoiding: avoiding) else { return (nil, systems) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return (nil, systems) }
        encoder.label = "Reduced-resolution particles"
        var left: [ParticleSystemRuntime] = []
        for system in systems where !particleMaterials.draw(system, alsoInto: target.pixelFormat, sampleCount: 1,
                                                            depthFormat: .invalid, encoder: encoder,
                                                            commandBuffer: commandBuffer, context: context(system)) {
            left.append(system)
        }
        encoder.endEncoding()
        return (left.count < systems.count ? target : nil, left)
    }

    /// Steps a system whose object is hidden (`ParticleFrameInputs.hidden`): the one step that
    /// clears it runs on the GPU; nothing is drawn.
    func stepHiddenParticles(_ system: ParticleSystemRuntime, deltaTime: Float, pixelFormat: MTLPixelFormat) {
        // The GPU's count is its last finished step's.
        let holdsParticles = system.gpu.map { $0.completedCount > 0 } ?? false
        guard let inputs = ParticleFrameInputs.hidden(system, deltaTime: deltaTime, holdsParticles: holdsParticles) else { return }
        let rendererName = system.configuration.rendererName
        if let simulated = particleMaterials?.prepareSimulated(system, pixelFormat: pixelFormat, sampleCount: sceneSampleCount,
                                                               depthFormat: sceneDepthFormat) {
            particleRequests.append(.init(system: system, inputs: inputs,
                                          kind: .material(simulated.format, rendererName: rendererName),
                                          materialVertexCount: simulated.vertexCount))
        } else {
            particleRequests.append(.init(system: system, inputs: inputs, kind: .fallback(rendererName: rendererName)))
        }
    }

    /// A step as scripts' playback leaves it: paused emits nothing (its clock stands still),
    /// stopped clears the system; `emitParticles(count)` adds a burst of `count`.
    static func applyScriptPlayback(_ playback: SceneScriptObjectCommand.Playback?, emitting count: Int?,
                                    to inputs: inout ParticleFrameInputs) {
        switch playback {
        case .pause?:
            for index in inputs.emitters.indices {
                inputs.emitters[index].rate = 0
                inputs.emitters[index].burst = 0
            }
        case .stop?:
            inputs.clears = true
        case .play?, nil:
            break
        }
        if let count, !inputs.emitters.isEmpty { inputs.emitters[0].burst += count }
    }

    /// The parallax offset of a particle object: its root object's live origin and `parallaxDepth`.
    private func particleParallaxOffset(_ id: String, motion: CameraMotion) -> SIMD2<Float> {
        guard let parallax = motion.parallax else { return .zero }
        let rootID = transforms.root(of: id)
        guard let node = transforms.nodes[rootID] else { return .zero }
        let rootLocal = liveLocal(rootID) ?? node.local
        return parallax.state.offset(rootOrigin: rootLocal.origin, rootDepth: parallaxDepth(of: rootID, node: node),
                                     amount: parallax.amount)
    }

    /// Hands the vertex stage the quad's full axes (parent rotation and non-uniform scale), in
    /// the same placement space `layerUniform` put its centre in.
    func setQuadAxes(_ uniform: inout LayerUniform, quad: SceneQuadGeometry) {
        let extent = quad.extent
        let placementScale = SIMD2<Float>(extent.x > 0 ? uniform.size.x / extent.x : 1,
                                          extent.y > 0 ? uniform.size.y / extent.y : 1)
        uniform.quadAxisX = quad.axisX * placementScale
        uniform.quadAxisY = quad.axisY * placementScale
        uniform.rotation = 0
    }
}
