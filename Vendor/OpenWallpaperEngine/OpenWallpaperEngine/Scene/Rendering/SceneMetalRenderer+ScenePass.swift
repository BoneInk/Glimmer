import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    /// The pass a layer's quad draws into: its target's format and samples, its depth states (nil
    /// without depth) and the native layer pipelines for it.
    struct LayerTarget {
        /// The target's size in pixels.
        var size: SIMD2<Float>
        var pixelFormat: MTLPixelFormat
        var sampleCount: Int
        var depth: SceneDepthStates?
        var pipelines: SceneLayerPipelines.Pipelines
    }

    /// Draws a layer's quad into `encoder`'s pass: through its material, or natively when it has
    /// none or its material can't draw this frame. `image` is its texture frame (its text raster
    /// for a text layer), `effectOutput` what its effects made this frame, `snapshot` the scene
    /// under it for a material that reads it. Leaves `target.pipelines.normal` set.
    func encodeLayer(_ entry: PreparedLayer, _ draw: LayerDraw, image: RenderTextureFrame,
                     effectOutput: MTLTexture?, drawnLastPass: EffectGraphRenderer.DrawnLastPass? = nil,
                     snapshot layerSnapshot: MTLTexture?, frame: BuiltinFrameContext,
                     target: LayerTarget, encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
        // Effects that started from the frame cut out of the atlas or the padded texture
        // (`effectInput`) made one image: the layer draws their output, or their last pass samples
        // their buffers, whole.
        let wholeFrame = spriteFrameVersions[entry.layer.id] == nil ? image
            : RenderTextureFrame(texture: image.texture, duration: image.duration, uvOrigin: .zero,
                                 uvAxisX: SIMD2(1, 0), uvAxisY: SIMD2(0, 1))
        let textureFrame = effectOutput != nil ? wholeFrame : image
        // The effects' last pass draws the layer: through its quad, with its material's blending and
        // depth state (`runEffectsDrawingLastPass`).
        if let drawnLastPass, let effectGraph, let blending = entry.layer.imageMaterial?.pass.blending ?? entry.layer.solidBlending {
            target.depth?.apply(layerRaster(entry), to: encoder)
            let placement = lastPassPlacement(blending: blending, draw: draw, image: wholeFrame, sceneFormat: target.pixelFormat)
            let context = effectContext(entry, draw: draw, input: drawnLastPass.input, snapshot: nil, frame: frame)
            let drew = effectGraph.encode(drawnLastPass, into: encoder, scene: placement, context: context,
                                          commandBuffer: commandBuffer)
            encoder.setRenderPipelineState(target.pipelines.normal)
            if drew { return }
        }
        var uniform = layerUniform(position: draw.quad.center, size: draw.quad.extent,
                                   opacity: draw.opacity, drawableSize: target.size, placement: .stretch)
        setQuadAxes(&uniform, quad: draw.quad)
        // Text is rasterised white; its user colour tints it when drawn, like its authored one.
        // Text with font effects or layer effects has its colours in its raster (`textFill`).
        let textTint = entry.layer.text == nil ? SIMD3<Float>(repeating: 1) : self.textTint(layerID: entry.layer.id)
        uniform.color = !textRastersInColor(entry) && entry.layer.weEffects.isEmpty ? draw.color * SIMD4(textTint, 1)
            : SIMD4(1, 1, 1, draw.color.w)
        // The layer's brightness and a video's music-synced saturation; the other adjustments
        // stay at their identity (`layerUniform`).
        uniform.effects.x = draw.brightness
        uniform.effects.z = 1 + (entry.layer.musicSync?.saturationAmount ?? 0) * Float(draw.musicSyncLevel)
        uniform.uvOrigin = textureFrame.uvOrigin
        uniform.uvAxisX = textureFrame.uvAxisX
        uniform.uvAxisY = textureFrame.uvAxisY
        // A text layer's `font` material reads the glyphs' coverage; colour glyphs have none.
        // A prelit layer whose chain rendered nothing (every effect hidden, or compiling) draws
        // its prelit image: its own draw has the lighting off, so the raw image would be unlit.
        let materialTexture = entry.layer.text == nil
            ? effectOutput ?? prelitImages[entry.layer.id] ?? textureFrame.texture
            : textureFrame.coverage
        if let plan = entry.layer.imageMaterial, let imageMaterials, let materialTexture, imageMaterials.draw(plan, ImageMaterialRenderer.Draw(
               layerID: entry.layer.id, quad: draw.quad, sceneSize: sceneSize,
               color: SIMD3(draw.color.x, draw.color.y, draw.color.z) * textTint, alpha: draw.opacity, brightness: draw.brightness,
               texture: materialTexture, contentSize: entry.layer.source.contentSize,
               uvOrigin: textureFrame.uvOrigin, uvAxisX: textureFrame.uvAxisX, uvAxisY: textureFrame.uvAxisY,
               sceneSnapshot: layerSnapshot, mipMappedFrameBuffer: mipMappedTarget, shadowAtlas: frameShadowAtlas,
               frame: frame,
               values: timelines.values,
               assetTexture: { [unowned self] key, source in
                   self.puppetWarps[entry.layer.id]?[key] ?? self.effectAssetTexture(key: key, source: source)
               },
               assetSprite: { [unowned self] key, source in self.effectAssetSprite(key: key, source: source) },
               ignoredAdjustments: !ImageMaterialRenderer.nativeAdjustmentsAreIdentity(uniform, brightness: draw.brightness),
               placement: draw.placement, raster: layerRaster(entry)),
               pixelFormat: target.pixelFormat, sampleCount: target.sampleCount, depth: target.depth, encoder: encoder,
               commandBuffer: commandBuffer) {
            encoder.setRenderPipelineState(target.pipelines.normal)
            return
        }
        if entry.layer.imageMaterial != nil { imageMaterialFallbacks[entry.layer.id, default: 0] += 1 }
        target.depth?.apply(layerRaster(entry), to: encoder)
        let additive = entry.layer.additive
        if var placed = draw.placement?.native,
           let pipeline = additive ? target.pipelines.placedAdditive : target.pipelines.placedNormal {
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&placed, length: MemoryLayout<LayerPlacement3D>.stride, index: 1)
        } else if additive {
            encoder.setRenderPipelineState(target.pipelines.additive)
        }
        if effectOutput == nil { encodeTextBackground(entry, uniform: uniform, encoder: encoder) }
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(effectOutput ?? textureFrame.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if draw.placement != nil || additive { encoder.setRenderPipelineState(target.pipelines.normal) }
    }

    /// A text layer's `opaquebackground` box, when it is drawn as its own quad (no effects): the
    /// layer's quad in `backgroundcolor` (times `backgroundbrightness` where WE applies
    /// brightness), with the layer's opacity, before its glyphs, which then draw over it with that
    /// opacity too. That is WE's buffer, cleared to the colour with the object's alpha and the
    /// glyphs drawn into it with that alpha (0x140257c30), then composited.
    private func encodeTextBackground(_ entry: PreparedLayer, uniform: LayerUniform, encoder: MTLRenderCommandEncoder) {
        guard let authored = entry.layer.text, entry.layer.weEffects.isEmpty else { return }
        let text = scripts.text(authored, of: entry.layer.id).text
        guard text.opaqueBackground, let white = solidWhiteTexture else { return }
        var box = uniform
        let brightness = renderSettings.appliesBrightness ? max(text.backgroundBrightness, 0) : 1
        box.color = SIMD4(text.backgroundColor * brightness, uniform.color.w)
        box.effects.x = 1
        box.uvOrigin = .zero
        box.uvAxisX = SIMD2(1, 0)
        box.uvAxisY = SIMD2(0, 1)
        encoder.setVertexBytes(&box, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&box, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(white, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// This frame's `_rt_Reflection` (docs/models-plan.md §2.11): while a model is reflective, the
    /// visible reflected objects drawn through the mirrored camera in the object loop's order (its
    /// sort keyed on the mirrored forward, as WE sorts inside the mirrored pass), or the clear
    /// colour with the reflection setting off; nil while no model is reflective. It is drawn once
    /// the layers' effects and the particle systems' steps of this frame are encoded, before the
    /// scene pass that samples it: the layers draw this frame's images, as WE's object draws do.
    /// `draws`, `image` (a layer's texture frame, or text raster) and `effectOutputs` are the scene
    /// pass's, by layer index; `batches` its particle systems, and which of them draw through their
    /// material.
    func drawReflection(frame: BuiltinFrameContext, scene: MTLTexture, draws: [Int: LayerDraw],
                        image: (Int) -> RenderTextureFrame, effectOutputs: [Int: MTLTexture],
                        batches: [(system: ParticleSystemRuntime, material: Bool)],
                        commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let planarReflection, let modelDrawing, let depthStates, planarReflection.isNeeded(spatial.models) else {
            if planarReflection?.texture != nil { planarReflection?.release() }
            return nil
        }
        let reflectedModels = Set(planarReflection.reflectedList(spatial.models))
        let sequence = drawSequence(batches: batches.map(\.system), forward: ScenePlanarReflection.mirrored(frame.camera).forward)
        var objects: [ScenePlanarReflection.Object] = []
        var next = 0
        func systems(before barrier: Int) {
            while next < sequence.batchOrder.count, sequence.batchKeys[next] < barrier {
                let batch = batches[sequence.batchOrder[next]]
                next += 1
                if batch.material, let object = reflectedSystem(batch.system) { objects.append(object) }
            }
        }
        for (item, barrier) in sequence.items {
            systems(before: barrier)
            switch item {
            case .model(let index):
                let model = spatial.models[index]
                guard reflectedModels.contains(index), scripts.isVisible(model.id) else { continue }
                objects.append(.model(model, world: drawnWorld3D(model.id)))
            case .layer(let index):
                guard let draw = draws[index] else { continue }
                if let object = reflectedLayer(index, draw, image: image(index), effectOutput: effectOutputs[index]) {
                    objects.append(object)
                }
            case .particles:
                continue
            }
        }
        systems(before: .max)
        let pass = ScenePlanarReflection.Pass(
            width: scene.width, height: scene.height, pixelFormat: scene.pixelFormat,
            clearColor: scripts.state.scene.vector3(.clearcolor) ?? clearColor, enabled: renderSettings.reflection,
            objects: objects,
            frame: frame, values: timelines.values, mipMappedFrameBuffer: mipMappedTarget, shadowAtlas: frameShadowAtlas,
            assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
            layerComposite: { [unowned self] id in self.layerComposites[id] })
        return planarReflection.encode(pass, drawing: modelDrawing, depthStates: depthStates, commandBuffer: commandBuffer)
    }

    /// A layer's draw into the planar reflection, or nil when it isn't in the reflected list (its
    /// `reflected`, or a shape) or hidden. Drawn as in the scene pass with the mirrored camera:
    /// through it where the scene pass draws through the frame camera (a perspective scene's
    /// layers; an orthographic scene's, whose view the mirror makes a camera placement), and
    /// unchanged where WE's view doesn't reach the layer (a fullscreen layer in screen space, a
    /// `perspective` layer through its own temporary camera, 0x1401e5b60). A layer whose image
    /// is made inside the scene pass (it reads the scene, or samples a layer that does) isn't
    /// drawn: its image doesn't exist yet (docs/models-plan.md §4.3 M9).
    private func reflectedLayer(_ index: Int, _ draw: LayerDraw, image: RenderTextureFrame,
                                effectOutput: MTLTexture?) -> ScenePlanarReflection.Object? {
        let entry = layers[index]
        let id = entry.layer.id
        guard scripts.isVisible(id), spatial.isReflected(id), !entry.layer.readsScene,
              !compositeOrder().inScene.contains(id) else { return nil }
        return .other(id: id) { [unowned self] mirrored in
            var reflected = draw
            if self.isPerspective, var placement = draw.placement {
                placement.camera = mirrored.frame.camera
                reflected.placement = placement
            } else if !self.isPerspective, draw.placement == nil, !entry.layer.fillsScene {
                reflected.placement = SceneLayerPlacement(world: ImageMaterialRenderer.modelMatrix(draw.quad),
                                                          size: draw.quad.extent, camera: mirrored.frame.camera)
            }
            guard let pipelines = self.layerPipelines.pipelines(for: mirrored.pixelFormat, sampleCount: 1,
                                                                depthFormat: SceneDepthStates.format) else { return }
            mirrored.encoder.setRenderPipelineState(pipelines.normal)
            let size = SIMD2<Float>(Float(self.sceneRenderTargetSize.x), Float(self.sceneRenderTargetSize.y))
            self.encodeLayer(entry, reflected, image: image, effectOutput: effectOutput, snapshot: nil, frame: mirrored.frame,
                             target: LayerTarget(size: size, pixelFormat: mirrored.pixelFormat, sampleCount: 1,
                                                 depth: mirrored.depth, pipelines: pipelines),
                             encoder: mirrored.encoder, commandBuffer: mirrored.commandBuffer)
        }
    }

    /// A particle system's draw into the planar reflection through its material, or nil when it
    /// isn't in the reflected list or reads the scene drawn so far (refraction; that scene isn't
    /// the reflection's). Its camera is the mirrored one, except a `perspective` system's
    /// temporary camera in an orthographic scene, which WE's view doesn't reach.
    private func reflectedSystem(_ system: ParticleSystemRuntime) -> ScenePlanarReflection.Object? {
        guard let particleMaterials, !particleMaterials.readsSceneSnapshot(system) else { return nil }
        let id = particleObjectID(system)
        if let id, !spatial.isReflected(id) { return nil }
        return .other(id: id ?? "particles") { [unowned self] mirrored in
            // `particlePlacement` keeps a `perspective` system's temporary camera; an orthographic
            // scene's other systems take the mirrored orthographic view.
            let placement = self.particlePlacement(system, camera: mirrored.frame.camera)
                ?? ParticleMaterialUniforms.Placement(camera: mirrored.frame.camera)
            particleMaterials.draw(system, alsoInto: mirrored.pixelFormat, sampleCount: 1, depthFormat: SceneDepthStates.format,
                                   encoder: mirrored.encoder, commandBuffer: mirrored.commandBuffer, context: .init(
                                       sceneSize: self.sceneSize, frame: mirrored.frame, values: self.timelines.values,
                                       assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                                       sceneSnapshot: nil, mipMappedFrameBuffer: self.mipMappedTarget, shadowAtlas: self.frameShadowAtlas,
                                       depth: mirrored.depth, placement: placement))
        }
    }

    /// With `clearenabled` off (WE skips its scene pass's clear, 0x140183588), the pass loads the
    /// last frame's colour and depth instead of clearing them, while it draws into the same targets.
    /// New targets start black, not `clearcolor`: nothing ever clears them to it (WE 2.8.0.42,
    /// capture 542: the background of a 0.15 grey clear colour shows black), and at the far depth.
    func keepScene(_ pass: MTLRenderPassDescriptor, scene: MTLTexture, multisampled: MTLTexture?) {
        guard keepsScene else {
            keptSceneTargets = []
            return
        }
        let targets: [ObjectIdentifier?] = [ObjectIdentifier(scene), multisampled.map(ObjectIdentifier.init),
                       frameDepth == nil ? nil : depthBuffer.texture.map(ObjectIdentifier.init),
                       frameDepth == nil ? nil : depthBuffer.multisampled.map(ObjectIdentifier.init)]
        guard targets == keptSceneTargets else {
            keptSceneTargets = targets
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            return
        }
        pass.colorAttachments[0].loadAction = .load
        if frameDepth != nil { pass.depthAttachment.loadAction = .load }
    }

    /// Ends an encoder of the scene pass, storing only what is read afterwards: the samples and
    /// depth when the pass `resumes` onto them; else the resolved colour, and the depth only when
    /// a frame stage reads it (`SceneFrameStage.readsSceneDepth`). Every scene-pass encoder ends
    /// here, as their attachments' store actions are left `.unknown` until then.
    func endScenePass(_ encoder: MTLRenderCommandEncoder, resumes: Bool) {
        if sceneMultisampleTarget != nil {
            encoder.setColorStoreAction(resumes ? .storeAndMultisampleResolve : .multisampleResolve, index: 0)
        }
        if frameDepth != nil {
            let read = !resumes && frameStages.contains { $0.readsSceneDepth(settings: renderSettings) }
            encoder.setDepthStoreAction(depthBuffer.storeAction(resumes: resumes, read: read))
        }
        encoder.endEncoding()
    }

    /// Continues the scene pass after a pause (a snapshot of it, or effects run in between).
    func resumeScenePass(on scene: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLRenderCommandEncoder? {
        let resume = MTLRenderPassDescriptor()
        Self.attachScene(scene, multisampled: sceneMultisampleTarget, to: resume)
        resume.colorAttachments[0].loadAction = .load
        if frameDepth != nil { depthBuffer.attach(to: resume, clear: false) }
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: resume)
        encoder?.setRenderPipelineState(renderPipeline)
        return encoder
    }

    /// The scene drawn so far (`_rt_FullFrameBuffer`), current within `rect` (all of it when nil).
    /// Every scene-reading draw of a frame shares one full-size target, and only what changed is
    /// copied (`SceneSnapshotTracker`): the GPU runs the command buffer in order, so each draw
    /// reads its snapshot before the next copy overwrites any of it.
    func sceneSnapshot(of scene: MTLTexture, commandBuffer: MTLCommandBuffer,
                       needing rect: SceneSnapshotTracker.Rect? = nil) -> MTLTexture? {
        if sceneCopy == nil {
            // The reflection copy's level 0 when this frame allows (`snapshotCanShare`): one
            // full-size target fewer.
            let shared = snapshotSharesMipMappedTarget ? mipMappedTarget.flatMap {
                $0.width == scene.width && $0.height == scene.height && $0.pixelFormat == scene.pixelFormat ? $0 : nil
            } : nil
            sceneCopy = shared ?? renderTargetPool.texture(width: scene.width, height: scene.height,
                                                           pixelFormat: scene.pixelFormat, avoiding: scene)
            snapshotTracker.reset()
        }
        guard let copy = sceneCopy else { return nil }
        let whole = SceneSnapshotTracker.Rect(x: 0, y: 0, width: scene.width, height: scene.height)
        guard let region = snapshotTracker.copy(for: rect ?? whole) else { return copy }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            snapshotTracker.reset()
            return nil
        }
        let origin = MTLOrigin(x: region.x, y: region.y, z: 0)
        blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin,
                  sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                  to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blit.endEncoding()
        return copy
    }

    /// The scene under a scene-input layer, as that layer's base image (`SceneRegionResample`).
    /// A quad that is exactly the scene (composition and fullscreen layers) uses the snapshot as is.
    /// Under WE's texture reduction a composition layer's buffers are its size over the reduction;
    /// a fullscreen layer's aren't (`TextureReduction`). Drawn through a 3D camera (`placement`), it
    /// is the scene under the projected quad (`SceneRegionProjection`).
    func sceneRegion(of snapshot: MTLTexture, under quad: SceneQuadGeometry, placement: SceneLayerPlacement?,
                     reducedFor layer: SceneMetalLayer, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let reduction = layer.fillsScene ? 1 : Float(renderSettings.textureReduction)
        if let placement {
            guard let projection = regionProjection,
                  let size = SceneRegionResample.targetSize(extent: placement.size, layerSize: layer.size,
                                                            pixelsPerUnit: renderPixelsPerUnit / reduction),
                  let region = renderTargetPool.texture(width: size.x, height: size.y, pixelFormat: snapshot.pixelFormat,
                                                        avoiding: snapshot),
                  projection.draw(snapshot, under: placement, into: region, commandBuffer: commandBuffer) else { return nil }
            return region
        }
        if reduction == 1, !layer.clearsSceneAlpha, SceneRegionResample.coversWholeScene(quad, sceneSize: sceneSize) { return snapshot }
        guard let size = SceneRegionResample.targetSize(quad, layerSize: layer.size, pixelsPerUnit: renderPixelsPerUnit / reduction),
              let region = renderTargetPool.texture(width: size.x, height: size.y,
                                                    pixelFormat: snapshot.pixelFormat, avoiding: snapshot) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = region
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniform = SceneRegionResample.uniform(quad, sceneSize: sceneSize, targetSize: size)
        let pipelines = layerPipelines.pipelines(for: region.pixelFormat)
        // Copied over the cleared target without its alpha, the layer's base keeps alpha 0.
        encoder.setRenderPipelineState(layer.clearsSceneAlpha ? pipelines.colourCopy : pipelines.copy)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(snapshot, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return region
    }

    /// The scene target, at `renderPixelsPerUnit` pixels per scene unit.
    /// Draws into `multisampled` when there is one, resolving into `scene` whenever the pass
    /// ends (so a pause for a scene-reading layer resolves what's drawn so far, as WE resolves its
    /// multisampled target before reading `_rt_FullFrameBuffer`, 0x1400d3310); else into `scene`.
    /// The samples are kept only while the pass resumes: `endScenePass` sets the store action.
    static func attachScene(_ scene: MTLTexture, multisampled: MTLTexture?, to pass: MTLRenderPassDescriptor) {
        let attachment = pass.colorAttachments[0]!
        if let multisampled {
            attachment.texture = multisampled
            attachment.resolveTexture = scene
            attachment.storeAction = .unknown
        } else {
            attachment.texture = scene
            attachment.storeAction = .store
        }
    }

    /// This frame's multisampled scene target for WE's MSAA setting, made or remade to match
    /// `scene`; nil without MSAA (or when it can't be made, logged, when the pass draws without).
    /// Sets `sceneSampleCount`.
    func sceneMultisample(for scene: MTLTexture) -> MTLTexture? {
        var samples = renderSettings.sceneSampleCount(on: device)
        if samples > 1, layerPipelines.pipelines(for: scene.pixelFormat, sampleCount: samples) == nil { samples = 1 }
        guard samples > 1 else {
            sceneMultisampleTarget = nil
            sceneSampleCount = 1
            return nil
        }
        if let target = sceneMultisampleTarget, target.width == scene.width, target.height == scene.height,
           target.pixelFormat == scene.pixelFormat, target.sampleCount == samples {
            sceneSampleCount = samples
            return target
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: scene.pixelFormat, width: scene.width,
                                                                  height: scene.height, mipmapped: false)
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = samples
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Could not allocate the \(scene.width)×\(scene.height) \(samples)× MSAA scene target; drawing without MSAA")
            sceneMultisampleTarget = nil
            sceneSampleCount = 1
            return nil
        }
        sceneMultisampleTarget = target
        sceneSampleCount = samples
        return target
    }

    func sceneRenderTarget(pixelFormat: MTLPixelFormat, size pixelSize: SIMD2<Int>) -> MTLTexture? {
        if let sceneRenderTarget, sceneRenderTargetSize == pixelSize, sceneRenderTarget.pixelFormat == pixelFormat {
            return sceneRenderTarget
        }

        // Owned outright, not pooled: the scene is drawn into for the whole frame, so a pooled
        // scratch request of the same size (a scene-input region) must never be handed it.
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: pixelSize.x,
                                                                         height: pixelSize.y, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            OWELog.error(.scene, "Could not allocate the \(pixelSize.x)×\(pixelSize.y) scene target")
            return nil
        }
        sceneRenderTarget = texture
        sceneRenderTargetSize = pixelSize
        return texture
    }

    /// Maps a scene-unit position and size onto `drawableSize` pixels. Scene draws use
    /// `.stretch` (the target has the scene's aspect); the composite uses the user's placement, at
    /// `pixelsPerPoint` (the frame's display by default).
    func layerUniform(position: SIMD2<Float>, size: SIMD2<Float>, opacity: Float,
                      drawableSize: SIMD2<Float>, placement: WallpaperPlacement,
                      pixelsPerPoint: Float? = nil) -> LayerUniform {
        let scale: Float
        switch placement {
        case .stretch:
            return LayerUniform(position: SIMD2<Float>(position.x * drawableSize.x / sceneSize.x,
                                                        position.y * drawableSize.y / sceneSize.y),
                                size: SIMD2<Float>(size.x * drawableSize.x / sceneSize.x,
                                                   size.y * drawableSize.y / sceneSize.y),
                                sceneSize: drawableSize, opacity: opacity, particleShape: 0, rotation: 0, color: SIMD4<Float>(repeating: 1),
                                uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1),
                                effects: SIMD4<Float>(1, 1, 1, 0), blur: 0,
                                colorEffects: SIMD4<Float>(0, 1, 0, 0.7), transform: SIMD4<Float>(0, 0, 0, 1),
                                transformScaleY: 1)
        case .fill, .zoom, .fit, .center:
            scale = ScenePlacementScale.scale(for: placement, sceneSize: sceneSize, drawableSize: drawableSize,
                                              pixelsPerPoint: pixelsPerPoint ?? drawablePixelsPerPoint)
        }
        let offset = (drawableSize - sceneSize * scale) / 2
        return LayerUniform(position: SIMD2<Float>(position.x * scale + offset.x,
                                                   position.y * scale + (drawableSize.y - sceneSize.y * scale - offset.y)),
                            size: size * scale, sceneSize: drawableSize, opacity: opacity,
                            particleShape: 0, rotation: 0, color: SIMD4<Float>(repeating: 1),
                            uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1),
                            effects: SIMD4<Float>(1, 1, 1, 0), blur: 0,
                            colorEffects: SIMD4<Float>(0, 1, 0, 0.7), transform: SIMD4<Float>(0, 0, 0, 1),
                            transformScaleY: 1)
    }
}
