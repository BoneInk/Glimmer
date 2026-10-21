import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    // MARK: - Detail layers at the output's backing pixels (`SceneNativeDetailLayers`)

    /// This frame's detail layers drawn at the output's pixels: their indices in draw order, the
    /// output's pixels per scene unit, the placement they are drawn with, for a shared frame the
    /// backing size it is made at so they keep their pixels (nil: the scene's size), and how they
    /// reach the output.
    struct NativeDetailPlan {
        var layers: [Int] = []
        var pixelsPerUnit: Float = 0
        var placement: WallpaperPlacement = .stretch
        var sharedSize: SIMD2<Int>?
        var mode = SceneNativeDetailLayers.Mode.direct
        /// The output's size in pixels the plan was made for.
        var outputSize = SIMD2<Int>(0, 0)
        /// `.patch`: the output pixels it covers (origin at the top left).
        var patch: SceneSnapshotTracker.Rect?
        /// The layers also go into the scene target, after everything else, for what reads the
        /// finished scene (WE's bloom, `_rt_MipMappedFrameBuffer`). The patch's base is then a copy
        /// of the target's `baseTexels` made before they are drawn.
        var feedsScene = false
        var baseTexels: SceneSnapshotTracker.Rect?
    }

    /// Which layers leave the scene pass this frame: none unless the output has more pixels per unit
    /// than the scene target and the post-process works per pixel (`ScenePostProcess.detailMode`);
    /// then the candidates nothing kept in the scene pass after them reads or covers
    /// (`SceneNativeDetailLayers.promoted`).
    func nativeDetailPlan(_ output: FrameOutput, destination: SceneFrameDestination, sequence: DrawSequence,
                          particleBatchCount: Int, draws: [Int: LayerDraw], compositeOrder: SceneLayerCompositeOrder,
                          frame: BuiltinFrameContext, scene: MTLTexture, sceneIsOutput: Bool) -> NativeDetailPlan {
        var plan = NativeDetailPlan()
        defer {
            if plan.layers.count != promotedDetailLayers {
                OWELog.info(.scene, "Detail layers drawn at the output's pixels: \(plan.layers.count)")
            }
            promotedDetailLayers = plan.layers.count
        }
        // WE's volumetrics add light over the finished scene from its depth, which a patch can't take.
        let frameBloom = liveBloom()
        guard promotesDetailLayers, !sceneIsOutput, !SceneVolumetrics.runs(volumetrics?.plan, settings: renderSettings),
              var mode = postProcess.detailMode(bloom: frameBloom, extras: appExtras(), settings: renderSettings,
                                                colorCorrection: colorCorrection(), display: displayOutput,
                                                fade: frame.camera.fade)
        else { return plan }
        let feedsScene = mipMappedTarget != nil || ScenePostProcess.runsBloom(frameBloom, settings: renderSettings)
        if feedsScene {
            mode = .patch
        }
        let outputSize: SIMD2<Float>
        switch output {
        case .view:
            outputSize = destination.viewports[0].drawableSize
            plan.placement = destination.placement
        case .shared(let viewports):
            let pixelsPerUnit = SceneRenderResolution.pixelsPerUnit(
                sceneSize: sceneSize, drawableSize: SceneViewport.largestDrawable(viewports),
                floorsAtAuthoredSize: renderSettings.floorsAtAuthoredSize, quantised: followsLiveResize)
            let size = SceneRenderResolution.targetSize(sceneSize: sceneSize, pixelsPerUnit: pixelsPerUnit)
            plan.sharedSize = size
            outputSize = SIMD2(Float(size.x), Float(size.y))
        }
        plan.outputSize = SIMD2(Int(outputSize.x.rounded()), Int(outputSize.y.rounded()))
        let placed = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: outputSize,
                                  placement: plan.placement)
        plan.pixelsPerUnit = placed.size.x / max(sceneSize.x, 1)
        guard SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: Float(scene.width) / max(sceneSize.x, 1),
                                                  outputPixelsPerUnit: plan.pixelsPerUnit) else {
            plan.sharedSize = nil
            return plan
        }
        let targetSize = SIMD2(scene.width, scene.height)
        var items: [SceneNativeDetailLayers.Item] = []
        var nextBatch = 0
        func batches(before barrier: Int) {
            while nextBatch < particleBatchCount, sequence.batchKeys[nextBatch] < barrier {
                items.append(.unbounded)
                nextBatch += 1
            }
        }
        for (item, barrier) in sequence.items {
            batches(before: barrier)
            switch item {
            case .layer(let index):
                guard let draw = draws[index] else { continue }
                let entry = layers[index]
                let id = entry.layer.id
                let readsScene = entry.layer.readsScene || compositeOrder.inScene.contains(id)
                    || entry.layer.imageMaterial?.readsSceneSnapshot == true
                let visible = scripts.isVisible(id) && !hiddenFromFrame(entry.layer)
                let candidate = SceneNativeDetailLayers.isCandidate(
                    isText: entry.layer.text != nil, isMediaImage: entry.layer.systemImage != nil, visible: visible,
                    compositeSource: compositeOrder.sources.contains(id) || models?.compositeLayerIDs.contains(id) == true,
                    hasLayerEffects: !entry.layer.weEffects.isEmpty, readsScene: readsScene,
                    isPuppet: entry.layer.puppet != nil, placed3D: draw.placement != nil)
                // A layer through a 3D camera covers what its projection does: anywhere.
                let bounds: SceneSnapshotTracker.Rect? = draw.placement != nil ? nil
                    : SceneSnapshotTracker.pixelRect(of: draw.quad, sceneSize: sceneSize, targetSize: targetSize) ?? .empty
                items.append(.layer(index: index, bounds: bounds, readsScene: readsScene, candidate: candidate))
            case .model, .particles:
                items.append(.unbounded)
            }
        }
        batches(before: .max)
        let promoted = SceneNativeDetailLayers.promoted(items)
        var promotedTexels: [SceneSnapshotTracker.Rect] = []
        plan.layers = items.compactMap { item -> Int? in
            guard case let .layer(index, bounds, _, _) = item, promoted.contains(index) else { return nil }
            if let bounds { promotedTexels.append(bounds) }
            return index
        }
        plan.mode = mode
        plan.feedsScene = feedsScene
        if mode == .patch {
            // The output pixels the layers' texels (padded for the filters) land on.
            let placedRect = SceneNativeDetailLayers.placedViewport(center: placed.position, size: placed.size,
                                                                    outputSize: outputSize)
            guard let texels = SceneNativeDetailLayers.union(promotedTexels),
                  let patch = SceneNativeDetailLayers.outputRect(ofTexels: texels, sceneTexels: targetSize,
                                                                 placed: placedRect, outputSize: plan.outputSize)
            else {
                // Nothing of them is on the output: they stay in the scene pass.
                plan.layers = []
                plan.sharedSize = nil
                return plan
            }
            plan.patch = patch
            if feedsScene {
                plan.baseTexels = SceneNativeDetailLayers.texels(under: patch, sceneTexels: targetSize, placed: placedRect)
            }
        }
        if plan.layers.isEmpty { plan.sharedSize = nil }
        return plan
    }

    /// Draws the promoted layers `indices` (in draw order) after the scene pass, at the scene
    /// target's pixels, into the resumed scene pass: what reads the finished scene sees them as
    /// before (`NativeDetailPlan.feedsScene`). First copies the target's `baseTexels`, the scene
    /// without them that the patch is drawn over (`base`, nil when the copy can't be made).
    /// `resumed` false: the scene pass couldn't resume, and `encoder` is ended.
    func feedDetailLayers(_ indices: [Int], baseTexels: SceneSnapshotTracker.Rect?, draws: [Int: LayerDraw],
                          image: (Int) -> RenderTextureFrame, scene: MTLTexture, frame: BuiltinFrameContext,
                          encoder: inout MTLRenderCommandEncoder,
                          commandBuffer: MTLCommandBuffer) -> (resumed: Bool, base: MTLTexture?) {
        endScenePass(encoder, resumes: true)
        var base: MTLTexture?
        if let region = baseTexels, region.width > 0, region.height > 0,
           let copy = renderTargetPool.texture(width: region.width, height: region.height, pixelFormat: scene.pixelFormat,
                                               avoiding: scene),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: scene, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                      sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                      to: copy, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            base = copy
        }
        guard let resumed = resumeScenePass(on: scene, commandBuffer: commandBuffer) else { return (false, nil) }
        encoder = resumed
        let target = LayerTarget(size: SIMD2(Float(scene.width), Float(scene.height)), pixelFormat: scene.pixelFormat,
                                 sampleCount: sceneSampleCount, depth: frameDepth, pipelines: scenePassPipelines)
        for index in indices {
            guard let draw = draws[index] else { continue }
            encodeLayer(layers[index], draw, image: image(index), effectOutput: nil, snapshot: nil, frame: frame,
                        target: target, encoder: encoder, commandBuffer: commandBuffer)
        }
        return (true, base)
    }

    /// The detail patch (`SceneNativeDetailLayers.Mode.patch`): the output pixels `rect` of the
    /// scene as the composite upscales it, from `base` (a copy of the scene target's `baseTexels`,
    /// or with nil the whole texture the composite reads), with the promoted layers drawn over it at
    /// those pixels. `composite` is the composite's quad on the output, before its adjustments. Nil
    /// when its target can't be had.
    func detailPatch(_ plan: NativeDetailPlan, rect: SceneSnapshotTracker.Rect, base: MTLTexture,
                     baseTexels: SceneSnapshotTracker.Rect?, sceneTexels: SIMD2<Int>, composite: LayerUniform,
                     draws: [Int: LayerDraw], image: (Int) -> RenderTextureFrame, frame: BuiltinFrameContext,
                     commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let patch = renderTargetPool.texture(width: rect.width, height: rect.height, pixelFormat: base.pixelFormat,
                                                   avoiding: base) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = patch
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = SceneFrameDestination.clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        defer { encoder.endEncoding() }
        encoder.label = "detail patch"
        let pipelines = layerPipelines.pipelines(for: patch.pixelFormat)
        // The scene's quad as the composite draws it, moved into the patch and read with the same
        // linear filter, alpha included (the layers blend over it as over the scene target).
        var uniform = composite
        uniform.sceneSize = SIMD2(Float(rect.width), Float(rect.height))
        uniform.position = SceneNativeDetailLayers.patchPosition(composite.position, rect: rect, outputHeight: plan.outputSize.y)
        if let baseTexels {
            let uv = SceneNativeDetailLayers.copyUV(of: baseTexels, sceneTexels: sceneTexels)
            uniform.uvOrigin = uv.origin
            uniform.uvAxisX = uv.axisX
            uniform.uvAxisY = uv.axisY
        }
        encoder.setRenderPipelineState(pipelines.copy)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(base, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encodeNativeDetailLayers(plan.layers, draws: draws, image: image, into: encoder, target: patch,
                                 origin: SIMD2(Float(rect.x), Float(rect.y)),
                                 outputSize: SIMD2(Float(plan.outputSize.x), Float(plan.outputSize.y)),
                                 placement: plan.placement, frame: frame, commandBuffer: commandBuffer)
        return patch
    }

    /// Adds `bloom` (`_rt_Bloom`) to the detail patch `rect` as WE's `combine_ldr` adds it to the
    /// frame: read at each pixel's place in the scene with the linear filter, the sum stored in the
    /// patch's format. `composite` is the composite's quad on the output.
    func addBloom(_ bloom: MTLTexture, to patch: MTLTexture, rect: SceneSnapshotTracker.Rect,
                  composite: LayerUniform, outputHeight: Int, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = patch
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "detail patch bloom"
        var uniform = composite
        uniform.sceneSize = SIMD2(Float(rect.width), Float(rect.height))
        uniform.position = SceneNativeDetailLayers.patchPosition(composite.position, rect: rect, outputHeight: outputHeight)
        encoder.setRenderPipelineState(layerPipelines.pipelines(for: patch.pixelFormat).addCopy)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(bloom, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Draws `indices` (in draw order) over `texture` once the composite has put the scene on it
    /// (`SceneNativeDetailLayers.Mode.direct`).
    func drawNativeDetailLayers(_ indices: [Int], draws: [Int: LayerDraw], image: (Int) -> RenderTextureFrame,
                                onto texture: MTLTexture, placement: WallpaperPlacement, frame: BuiltinFrameContext,
                                commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        let outputSize = SIMD2<Float>(Float(texture.width), Float(texture.height))
        encodeNativeDetailLayers(indices, draws: draws, image: image, into: encoder, target: texture, origin: .zero,
                                 outputSize: outputSize, placement: placement, frame: frame, commandBuffer: commandBuffer)
    }

    /// Encodes `indices` into `encoder`, whose `target` is the output's pixels from `origin` (top
    /// left) on: each layer as the scene pass draws it, through a viewport on the scene's placed
    /// rect, so its quad, opacity, colour, blend and parallax land on the same pixels at the
    /// output's density.
    private func encodeNativeDetailLayers(_ indices: [Int], draws: [Int: LayerDraw], image: (Int) -> RenderTextureFrame,
                                          into encoder: MTLRenderCommandEncoder, target texture: MTLTexture,
                                          origin: SIMD2<Float>, outputSize: SIMD2<Float>, placement: WallpaperPlacement,
                                          frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) {
        let placed = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: outputSize,
                                  placement: placement)
        var viewport = SceneNativeDetailLayers.placedViewport(center: placed.position, size: placed.size, outputSize: outputSize)
        viewport.origin -= origin
        // Only the placed scene within the target: a cropping placement's viewport reaches past it.
        let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
        let low = simd_clamp(viewport.origin.rounded(.down), SIMD2<Float>(0, 0), size)
        let high = simd_clamp((viewport.origin + viewport.size).rounded(.up), SIMD2<Float>(0, 0), size)
        guard high.x > low.x, high.y > low.y else { return }
        encoder.setViewport(MTLViewport(originX: Double(viewport.origin.x), originY: Double(viewport.origin.y),
                                        width: Double(viewport.size.x), height: Double(viewport.size.y), znear: 0, zfar: 1))
        encoder.setScissorRect(MTLScissorRect(x: Int(low.x), y: Int(low.y),
                                              width: Int(high.x - low.x), height: Int(high.y - low.y)))
        let pipelines = layerPipelines.pipelines(for: texture.pixelFormat)
        encoder.setRenderPipelineState(pipelines.normal)
        let target = LayerTarget(size: viewport.size, pixelFormat: texture.pixelFormat, sampleCount: 1, depth: nil,
                                 pipelines: pipelines)
        for index in indices {
            guard let draw = draws[index] else { continue }
            encodeLayer(layers[index], draw, image: image(index), effectOutput: nil, snapshot: nil, frame: frame,
                        target: target, encoder: encoder, commandBuffer: commandBuffer)
        }
    }
}
