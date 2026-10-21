import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Renders a frame for `view` alone and presents it there.
    func draw(in view: MTKView) {
        if drawsOnRenderThreadOnly { ThreadGuards.assertRenderThread("A scene frame") }
        ThreadGuards.renderFrame { renderFrame(.view(view)) }
    }

    /// Renders one frame for all the displays of a shared scene, at the largest scene target any
    /// of them needs; the cursor comes from the display it is on. Each display then shows the
    /// frame at its own size (`present(in:)`). The first viewport is the driving display, whose
    /// resolution scripts see.
    func renderShared(_ viewports: [SceneViewport]) {
        guard !viewports.isEmpty else { return }
        if drawsOnRenderThreadOnly { ThreadGuards.assertRenderThread("A shared scene frame") }
        ThreadGuards.renderFrame { renderFrame(.shared(viewports)) }
    }

    /// Draws the shared frame again (a loading snapshot, the lock screen's frame without the clock)
    /// without stepping the scene: no script frame, no clock, timeline or particle step. WE never
    /// steps a scene to take a picture of it.
    func redrawShared(_ viewports: [SceneViewport]) {
        redrawing = true
        defer { redrawing = false }
        renderShared(viewports)
    }

    /// Shows the latest shared frame (`renderShared`) on `view`, at its size and the user's
    /// placement: one pass per display. A stretched display shows its rect of the frame placed on
    /// the whole canvas.
    func present(in view: MTKView) {
        let headroom = viewHeadroom(view)
        sharedHeadrooms[ObjectIdentifier(view)] = headroom
        guard let frame = sharedFrame else { return }
        // The view shows the frame in its own format: EDR when the frame was drawn for it.
        let extended = frame.pixelFormat == SceneDisplayOutput.extendedPixelFormat && pixelFormat != frame.pixelFormat
        (extended ? SceneDisplayOutput.extendedRange(headroom: headroom.current) : .standard).apply(to: view, standard: pixelFormat)
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let size = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
        let snapshot = SceneViewSnapshots.snapshot(of: view)
        let pointWidth = snapshot.map { CGFloat($0.pointSize.x) } ?? view.bounds.width
        let pixelsPerPoint = pointWidth > 0 ? size.x / Float(pointWidth) : 1
        encodePlaced(frame, onto: encoder, size: size, pixelsPerPoint: pixelsPerPoint,
                     pipeline: extended ? layerPipelines.pipelines(for: frame.pixelFormat).copy : copyPipeline,
                     span: snapshot.flatMap { SceneCanvasSpan(snapshot: $0, pixelsPerPoint: pixelsPerPoint) })
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastPresentCommandBuffer = commandBuffer
    }

    /// Draws `frame` onto a `size`-pixel target at the user's placement, as a display shows it; on
    /// a stretch, placed on the canvas and seen through the display's rect of it (`span`).
    private func encodePlaced(_ frame: MTLTexture, onto encoder: MTLRenderCommandEncoder, size: SIMD2<Float>,
                              pixelsPerPoint: Float, pipeline: MTLRenderPipelineState, span: SceneCanvasSpan? = nil) {
        var uniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1,
                                   drawableSize: span?.canvasPixels ?? size,
                                   placement: placement, pixelsPerPoint: pixelsPerPoint)
        if let span { span.apply(to: &uniform, drawableSize: size) }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(frame, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    /// Draws the latest shared frame (`renderShared`) into `target`, in the drawables' format, as
    /// `present(in:)` shows it on a display of that size (a loading snapshot). False without one.
    func encodeSharedFrame(into target: MTLTexture, pixelsPerPoint: Float, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let frame = sharedFrame, target.pixelFormat == pixelFormat else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = SceneFrameDestination.clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        encodePlaced(frame, onto: encoder, size: SIMD2(Float(target.width), Float(target.height)),
                     pixelsPerPoint: pixelsPerPoint, pipeline: copyPipeline)
        encoder.endEncoding()
        return true
    }

    /// Frees the shared frame: a scene on one display draws straight onto its drawable and only
    /// rendered one for a loading snapshot. The GPU keeps what in-flight work still reads.
    func releaseSharedFrame() {
        sharedFrame = nil
        sharedFrameTarget = nil
    }

    /// Where a frame goes: one view's drawable, or a shared scene's finished frame.
    enum FrameOutput {
        case view(MTKView)
        case shared([SceneViewport])
    }

    /// The frame's pass onto `output` (nil for a shared frame until its size is known), its
    /// viewports and the placement the post-process composites with.
    private func frameDestination(_ output: FrameOutput) -> SceneFrameDestination? {
        switch output {
        case .view(let view):
            // The drawable is taken late (`lateOutput`, F1): its size and format are the view's,
            // which `selectDisplayOutput` set up.
            let size = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
            guard size.x >= 1, size.y >= 1 else { return nil }
            let format = SceneViewSnapshots.snapshot(of: view)?.layer?.pixelFormat ?? view.colorPixelFormat
            return SceneFrameDestination(descriptor: nil, drawable: nil, pixelFormat: format,
                                         placement: placement, viewports: [SceneViewport(view, drawableSize: size)])
        case .shared(let viewports):
            // The finished frame keeps the scene's aspect; each display places it when presenting.
            return SceneFrameDestination(descriptor: nil, drawable: nil, pixelFormat: pixelFormat, placement: .stretch,
                                         viewports: viewports)
        }
    }

    /// How this frame reaches the display (`SceneDisplayOutput`): EDR while the content draws in
    /// HDR under "displayhdr" and the screen has headroom, the view set up for it; a shared frame
    /// takes the least headroom of the views it was shown on since the last one.
    private func selectDisplayOutput(_ output: FrameOutput) {
        let headroom: SceneDisplayHeadroom
        switch output {
        case .view(let view):
            headroom = viewHeadroom(view)
        case .shared:
            let shown = Array(sharedHeadrooms.values)
            sharedHeadrooms.removeAll(keepingCapacity: true)
            headroom = shown.isEmpty ? SceneDisplayHeadroom()
                : SceneDisplayHeadroom(potential: shown.map(\.potential).min() ?? 1, current: shown.map(\.current).min() ?? 1)
        }
        displayOutput = SceneDisplayOutput.select(postProcessing: renderSettings.postProcessing, drawsHDR: postProcess.drawsHDR,
                                                  headroom: headroom)
        if case .view(let view) = output { displayOutput.apply(to: view, standard: pixelFormat) }
    }

    /// The pass onto a shared scene's finished frame, `width` × `height` (the scene's size, or the
    /// backing pixels its detail layers draw at), in this frame's output format (`displayOutput`).
    private func sharedFramePass(width: Int, height: Int) -> MTLRenderPassDescriptor? {
        let format = displayOutput.pixelFormat(standard: pixelFormat)
        if sharedFrameTarget?.width != width || sharedFrameTarget?.height != height
            || sharedFrameTarget?.pixelFormat != format {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            sharedFrameTarget = device.makeTexture(descriptor: descriptor)
            if sharedFrameTarget == nil {
                OWELog.error(.scene, "Could not allocate the \(width)×\(height) shared frame")
            }
        }
        guard let target = sharedFrameTarget else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = SceneFrameDestination.clearColor
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// This frame's scene target and, when the scene draws straight into its output, that output.
    private struct FrameTargets {
        var scene: MTLTexture
        /// Set when `scene` is the output (S2): the drawable's pass (or nil for a shared frame's,
        /// which is `scene` itself) and the drawable.
        var output: (descriptor: MTLRenderPassDescriptor?, drawable: CAMetalDrawable?)?
        var sceneIsOutput: Bool { output != nil }
        /// A shared frame that would draw straight into its scene target (S2) but keeps its own
        /// frame while its detail layers may be promoted (`sharedFrameGainsDetail`): when none is,
        /// the scene target is the frame after all, as it would have been.
        var deferredPassThrough = false
    }

    /// The scene target for this frame. When the post-process would change nothing and the
    /// composite would be a 1:1 copy (`ScenePostProcess.passesThrough`), the scene is drawn straight
    /// into its output instead (S2): the view's drawable, taken now, or for a shared frame the
    /// scene target is the frame its displays present. Else the scene's own target.
    private func frameTargets(_ output: FrameOutput, destination: SceneFrameDestination, format: MTLPixelFormat,
                              size: SIMD2<Int>, frame: BuiltinFrameContext) -> FrameTargets? {
        let outputSize = SIMD2<Float>(Float(size.x), Float(size.y))
        // A scene that keeps its last frame draws into its own target, never the drawable.
        let passesThrough = skipsIdentityComposite && !keepsScene && !drawsAtRenderScale && !postProcess.drawsHDR && format == destination.pixelFormat
            && postProcess.passesThrough(
                bloom: liveBloom(), extras: appExtras(), settings: renderSettings, colorCorrection: colorCorrection(),
                display: displayOutput, sceneSize: size, outputSize: size,
                placement: layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: outputSize,
                                        placement: destination.placement))
        if passesThrough, sharedFrameGainsDetail(output, sceneTargetSize: size) {
            return sceneRenderTarget(pixelFormat: format, size: size).map {
                FrameTargets(scene: $0, output: nil, deferredPassThrough: true)
            }
        }
        if passesThrough {
            switch output {
            case .view(let view):
                if let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                   drawable.texture.width == size.x, drawable.texture.height == size.y,
                   drawable.texture.pixelFormat == format {
                    // The scene's own target isn't needed while it draws into the drawable.
                    sceneRenderTarget = nil
                    sceneRenderTargetSize = .zero
                    lastDrawableScene = drawable.texture
                    return FrameTargets(scene: drawable.texture, output: (descriptor, drawable))
                }
            case .shared:
                if let scene = sceneRenderTarget(pixelFormat: format, size: size) {
                    sharedFrameTarget = nil
                    return FrameTargets(scene: scene, output: (Self.outputPass(onto: scene), nil))
                }
            }
        }
        return sceneRenderTarget(pixelFormat: format, size: size).map { FrameTargets(scene: $0, output: nil) }
    }

    /// Whether a shared frame of a content with detail layers would have more pixels per unit than
    /// its `sceneTargetSize` scene target: it then keeps its own frame, which its detail layers may
    /// draw onto at the displays' backing pixels (`nativeDetailPlan`), rather than being the scene.
    private func sharedFrameGainsDetail(_ output: FrameOutput, sceneTargetSize: SIMD2<Int>) -> Bool {
        guard promotesDetailLayers, case .shared(let viewports) = output,
              layers.contains(where: { $0.layer.text != nil || $0.layer.systemImage != nil }) else { return false }
        let pixelsPerUnit = SceneRenderResolution.pixelsPerUnit(
            sceneSize: sceneSize, drawableSize: SceneViewport.largestDrawable(viewports),
            floorsAtAuthoredSize: renderSettings.floorsAtAuthoredSize, quantised: followsLiveResize)
        return SceneNativeDetailLayers.gainsDetail(scenePixelsPerUnit: Float(sceneTargetSize.x) / max(sceneSize.x, 1),
                                                   outputPixelsPerUnit: pixelsPerUnit)
    }

    /// The pass the post-process composites onto, taken once the frame's work is encoded (F1): the
    /// view's drawable, or the shared frame. Nil (the frame isn't shown) without a drawable.
    private func lateOutput(_ output: FrameOutput, matching scene: MTLTexture, size: SIMD2<Int>? = nil)
        -> (descriptor: MTLRenderPassDescriptor?, drawable: CAMetalDrawable?) {
        switch output {
        case .view(let view):
            guard let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return (nil, nil) }
            return (descriptor, drawable)
        case .shared:
            return (sharedFramePass(width: size?.x ?? scene.width, height: size?.y ?? scene.height), nil)
        }
    }

    /// A pass whose attachment is `texture` as it stands: what the post-process's steps read when
    /// the scene is its own output (nothing composites onto it).
    private static func outputPass(onto texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    /// A shared frame's output when its scene target is the frame (`outputPass`), as `lateOutput` returns one.
    private static func passThroughOutput(onto scene: MTLTexture)
        -> (descriptor: MTLRenderPassDescriptor?, drawable: CAMetalDrawable?) {
        (outputPass(onto: scene), nil)
    }

    private func renderFrame(_ output: FrameOutput) {
        let frameStart = CACurrentMediaTime()
        let frameSignpost = OWESignpost.begin(OWESignpost.render, "frame")
        WallpaperServices.shared.beginFrame(wallpaper: wallpaperKey)
        renderTargetPool.endFrame()
        textFrameCache.beginGeneration()
        defer {
            // Compiles this frame started: the next frame draws differently once they land.
            if layerAnalysis != nil, pipelinesCompiling { analysedWarmUp = true }
            WallpaperServices.shared.endFrame()
            frameSignpost.end()
            frameTimeObserver?(CACurrentMediaTime() - frameStart)
            if OWEFrameMetrics.isReportingEnabled {
                OWEFrameMetrics.recordFrame(seconds: CACurrentMediaTime() - frameStart,
                                            layers: layers.count,
                                            particles: particleSystems.reduce(0) {
                                                $1.simulation != nil ? $0 : $0 + ($1.gpu?.completedCount ?? 0)
                                            })
            }
        }

        selectDisplayOutput(output)
        guard let destination = frameDestination(output) else { return }
        let viewports = destination.viewports
        drawablePixelsPerPoint = viewports[0].pixelsPerPoint
        // The largest target any display needs, so each shows the scene at its own density.
        let renderDrawable = SceneRenderResolution.drawableSize(viewports, resolution: renderSettings.renderResolution,
                                                                sceneSize: sceneSize)
        renderPixelsPerUnit = SceneRenderResolution.pixelsPerUnit(sceneSize: sceneSize, drawableSize: renderDrawable,
                                                                  floorsAtAuthoredSize: renderSettings.floorsAtAuthoredSize, quantised: followsLiveResize)
        // Drawn at the render scale (`GSUpscaling`): the composite scales the frame up bilinearly.
        drawsAtRenderScale = false
        // A scene that is one plain video draws it at exactly the display's density, so a target the
        // size of the drawable lets the video draw straight into it in one pass (S2), not into a
        // larger target resampled again by the composite.
        if let exact = videoOnlyPixelsPerUnit(renderDrawable) {
            renderPixelsPerUnit = exact
        } else if renderSettings.drawnScale < 1 {
            drawsAtRenderScale = true
            renderPixelsPerUnit = SceneRenderResolution.drawnPixelsPerUnit(renderPixelsPerUnit, scale: renderSettings.drawnScale)
        }
        // A scene drawn smaller than its authored size, or at the render scale, is below full
        // detail: what its buffers stand for.
        fullDetailScale = SceneRenderResolution.pixelsPerUnit(sceneSize: sceneSize, drawableSize: renderDrawable,
                                                              floorsAtAuthoredSize: true, quantised: followsLiveResize) / renderPixelsPerUnit
        // A content drawn in HDR draws into RGBA16F (docs/lighting-plan.md §2.6).
        let scenePixelFormat: MTLPixelFormat = postProcess.drawsHDR ? .rgba16Float : destination.pixelFormat
        let sceneTargetSize = SceneRenderResolution.targetSize(sceneSize: sceneSize, pixelsPerUnit: renderPixelsPerUnit)

        // Layers and particles are drawn in scene units onto a target at the output's pixel
        // density; placement scaling happens once, in the final composite pass.
        let drawableSize = SIMD2<Float>(Float(sceneTargetSize.x), Float(sceneTargetSize.y))
        clock.paused = pausesPlayback
        let rate = playbackRate?() ?? ScenePlaybackSpeed.speed(ofStore: wallpaperKey)
        if redrawing { clock.standStill() } else if holdsClock { clock.hold(at: wallTime()) } else { clock.advance(to: wallTime(), speed: rate) }
        let sceneTime = clock.time
        if clock.hasStopped { onPlaybackStopped?() }
        let time = Float(sceneTime)
        // What a script frame that overran the last draw's wait left (they run on their own thread, §4.5).
        let orderBefore = scripts.state.order
        if !redrawing { applyScriptEvents(scripts.beginFrame()) }
        // WE writes every timeline before the scripts run; a script's calls act on the next advance.
        let animationEvents = redrawing ? [] : timelines.advance(by: Float(clock.delta))
        drawProbe?.beginFrame()
        let cursorSample = fixedPointer.map { (position: $0 * sceneSize, onDisplay: false) }
            ?? cursorTracker.update(sceneCursor(viewports), sceneSize: sceneSize)
        let cursor = cursorSample.position
        // WE's scripts and `g_PointerState` see only clicks that land on the wallpaper.
        let leftDown = cursorSample.onDisplay
            && clickReader.isDown(scripts.services?.clicks?.state ?? DesktopClickMonitor.State())
        releaseFinishedEffectState()
        prelitImages.removeAll(keepingCapacity: true)
        spriteFrameVersions.removeAll(keepingCapacity: true)
        beginTransformFrame()
        advanceRigs()
        if scripts.isRunning && !redrawing {

            // Like WE, the scripts run before the frame that shows what they did (§4.4): this
            // frame's clock, cursor and animated values go in, and their results are drawn now
            // unless they overrun the wait (then they show from the next draw on).
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            submitScriptFrame(viewports: viewports, cursor: cursorSample, leftDown: leftDown,
                              animationEvents: animationEvents)
            scripts.record(since: start, newFrame: false)
            applyScriptEvents(scripts.finishFrame(waitingUpTo: scripts.frameWait))
            beginTransformFrame()
        }
        if scripts.state.order != orderBefore {
            orderLayers()
            beginTransformFrame()
        }
        updateSounds()
        var dynamicTextures: [Int: MTLTexture] = [:]
        // Layers whose effects' last pass draws into the scene (`runEffectsDrawingLastPass`).
        var drawnLastPasses: [Int: EffectGraphRenderer.DrawnLastPass] = [:]
        // Advanced once per frame: every advance smooths the spectrum one step further.
        var effectFrame = BuiltinFrameContext()
        frameSerial &+= 1
        effectFrame.serial = frameSerial
        effectFrame.time = sceneTime
        effectFrame.frameTime = clock.delta
        effectFrame.daytime = BuiltinFrameContext.daytime(at: Date())
        let pointer = simd_clamp(cursor / max(sceneSize, SIMD2(1, 1)), SIMD2(0, 0), SIMD2(1, 1))
        effectFrame.pointer = pointer
        effectFrame.pointerLast = lastPointer ?? pointer
        lastPointer = pointer
        effectFrame.pointerState = BuiltinFrameContext.pointerState(primaryDown: leftDown)
        effectFrame.screenSize = drawableSize
        effectFrame.textureReductionScale = Float(renderSettings.textureReduction)
        effectFrame.audio = audioSpectrumFrame(SceneClock.rate(rate))
        let motion = cameraMotion(pointer: pointer, time: time, deltaTime: Float(clock.delta))
        effectFrame.parallax = cameraParallax.isActive ? cameraParallax.shaderPosition(sceneSize: sceneSize) : SIMD2(0.5, 0.5)
        // WE's camera eye and forward (ctx+0x68, ctx+0x160). An orthographic scene's camera stays
        // still and the objects move by the shake instead (`SceneFrameLightingInput.cameraShake`).
        effectFrame.camera = cameraRig.frameCamera(cameraRigInput(time: sceneTime, motion: motion))
        if isPerspective { perspectiveCameraLock.withLock { perspectiveCamera = effectFrame.camera } }
        // An orthographic scene is drawn in its camera's drawn space: the zoom and the view a
        // camera layer or path gives it this frame (docs/models-plan.md §5.19).
        if !isPerspective { frameZoom = effectFrame.camera.drawnSpace }
        effectFrame.eyePosition = effectFrame.camera.eye
        effectFrame.viewForward = effectFrame.camera.forward
        // Spatialized sounds are placed against it from the next update on.
        sounds.listener = SceneSoundSpatialization.Listener(camera: effectFrame.camera,
                                                            orthographicSize: isPerspective ? nil : sceneSize)
        effectFrame.lighting = frameLighting(eye: effectFrame.eyePosition, forward: effectFrame.viewForward,
                                             shake: motion.shake)
        if frameStats != nil { lastLightCount = effectFrame.lighting.objects.count }
        analyseLayers(effectFrame: effectFrame, motion: motion, drawableSize: drawableSize)
        // While the stats overlay counts, every frame is drawn, so it shows what a frame costs.
        guard redrawing || paceFrame(effectFrame, at: wallTime()) || frameStats != nil else { return }
        keepsScene = !(scripts.state.scene.flag(.clearenabled) ?? clearEnabled)
        // Only a frame that is drawn takes its targets, and the drawable only once its work is
        // encoded (F1), unless the scene draws straight into it (`FrameTargets`, S2).
        let madeCommandBuffer = commandQueue.makeCommandBuffer()
        guard let commandBuffer = frameStats?.wrap(madeCommandBuffer) ?? madeCommandBuffer,
              let targets = frameTargets(output, destination: destination, format: scenePixelFormat, size: sceneTargetSize,
                                         frame: effectFrame) else { return }
        let sceneTexture = targets.scene
        if targets.sceneIsOutput { compositesSkipped += 1 }
        // Until the first complete frame: whether this one can be, and the compiles landed before it.
        let landedBefore = hasCompleteFrame || !hasContent || pipelinesCompiling ? nil : pipelinesLanded
        // The frames before it drew only what was ready: effect history starts with this one.
        if landedBefore != nil { effectGraph?.restartHistory() }
        let multisampledScene = sceneMultisample(for: sceneTexture)
        // Draws sample the last frame's copy; this frame's is made after the scene pass.
        mipMappedTarget = mipMappedFrameBuffer?.target(matching: sceneTexture, commandBuffer: commandBuffer)
        encodedFrames &+= 1
        // A HDR video converts its new frame before anything samples it (`VideoTextureStream`).
        for entry in layers { if case let .video(stream) = entry.layer.source { stream.prepareFrame(on: commandBuffer) } }
        drawProbe?.record(lighting: effectFrame.lighting)
        frameShadowAtlas = drawShadows(frame: effectFrame, commandBuffer: commandBuffer)
        // Text is rasterised first so its effects run on the finished text, like an image layer's.
        var textFrames: [Int: (frame: RenderTextureFrame, baseSize: SIMD2<Float>)] = [:]
        // Only visible layers get an entry; the draw loop skips the rest.
        var draws: [Int: LayerDraw] = [:]
        layerComposites.removeAll(keepingCapacity: true)
        let compositeOrder = self.compositeOrder()
        for layerIndex in compositeOrder.sequence {
            let entry = layers[layerIndex]
            // Hidden layers keep their transforms (scripts and hit tests read them) but draw nothing,
            // except into the image a model or another layer samples (`_rt_imageLayerComposite_<id>_a`).
            let visible = scripts.isVisible(entry.layer.id) && !hiddenFromFrame(entry.layer)
            let isCompositeSource = compositeOrder.sources.contains(entry.layer.id)
                || models?.compositeLayerIDs.contains(entry.layer.id) == true
            guard visible || isCompositeSource else { continue }
            if entry.layer.text != nil {
                // Drawn through a camera, text is as dense on screen as its projection makes it.
                let onScreen = layerPlacement(entry, size: layerBaseSize(entry), musicSyncLevel: 0, motion: motion,
                                              camera: effectFrame.camera)?.pixelsPerUnit(targetSize: drawableSize)
                    ?? { let world = frameZoom.plane * worldTransform(entry); return max(world.axisScale.x, world.axisScale.y) * renderPixelsPerUnit }()
                let pixelsPerUnit = SceneTextRasterScale.layer(onScreen: onScreen,
                                                               hasEffects: !entry.layer.weEffects.isEmpty)
                textFrames[layerIndex] = layerTextFrame(entry, boxSize: layerBaseSize(entry),
                                                        pixelsPerUnit: pixelsPerUnit)
            }
            // A puppet's mesh draws its image before anything reads it: its effects, its own draw.
            if let puppet = entry.layer.puppet {
                drawPuppet(puppet, entry, frame: effectFrame, compositeSource: isCompositeSource, commandBuffer: commandBuffer)
            }
            // Text's block is centred on its lines, not on the origin (`SceneTextLayout.boxCenter`);
            // a puppet's quad covers its canvas (`ScenePuppetCanvas`).
            var baseSize = textFrames[layerIndex]?.baseSize ?? layerBaseSize(entry)
            var contentOffset = textFrames[layerIndex]?.frame.textCenter ?? .zero
            if let canvas = puppetCanvases[entry.layer.id], let puppet = entry.layer.puppet {
                let scale = baseSize / puppet.imageSize
                baseSize = canvas.size * scale
                contentOffset = canvas.center * scale
            }
            var draw = layerDraw(entry, baseSize: baseSize, motion: motion, contentOffset: contentOffset)
            draw.placement = layerPlacement(entry, size: baseSize,
                                            musicSyncLevel: draw.musicSyncLevel, motion: motion, camera: effectFrame.camera)
            draw.placement?.offset += contentOffset
            // A hidden layer that runs in the scene pass still makes the image its readers sample.
            let runsInScene = entry.layer.readsScene || compositeOrder.inScene.contains(entry.layer.id)
            if visible || runsInScene { draws[layerIndex] = draw }
            // Layers that read the scene run inside the scene pass, once what's beneath them is drawn,
            // and so do the layers that sample them (`SceneLayerCompositeOrder.inScene`).
            if runsInScene { continue }
            if !entry.layer.weEffects.isEmpty {
                let input = solidEffectInput(entry.layer, commandBuffer: commandBuffer)
                    ?? effectInput(entry, image: textFrames[layerIndex]?.frame ?? textureFrame(for: entry), commandBuffer: commandBuffer)
                drawnLastPasses[layerIndex] = visible ? runEffectsDrawingLastPass(
                    entry, draw: draw, input: input, compositeSource: isCompositeSource, sceneFormat: sceneTexture.pixelFormat,
                    frame: effectFrame, commandBuffer: commandBuffer) : nil
                if drawnLastPasses[layerIndex] == nil {
                    dynamicTextures[layerIndex] = posedEffectOutput(
                        runEffects(entry, draw: draw, input: input, snapshot: nil, frame: effectFrame, commandBuffer: commandBuffer),
                        of: entry, camera: effectFrame.camera, commandBuffer: commandBuffer)
                }
            }
            if isCompositeSource {
                layerComposites[entry.layer.id] = dynamicTextures[layerIndex]
                    ?? solidEffectInput(entry.layer, commandBuffer: commandBuffer)
                    ?? compositeText(entry) ?? textureFrame(for: entry).texture
            }
        }
        // The next script frame reads this frame's text sizes and camera (WE's cursor pass and
        // `size` see the last drawn frame).
        lastTextSizes.removeAll(keepingCapacity: true)
        for (index, frame) in textFrames { lastTextSizes[layers[index].layer.id] = frame.baseSize }
        lastCameraMotion = motion
        lastFrameCamera = effectFrame.camera

        // WE clears the scene to `general.clearcolor` (the composite's letterbox stays black).
        let clear = scripts.state.scene.vector3(.clearcolor) ?? clearColor
        let sceneRenderPass = MTLRenderPassDescriptor()
        Self.attachScene(sceneTexture, multisampled: multisampledScene, to: sceneRenderPass)
        sceneRenderPass.colorAttachments[0].loadAction = .clear
        sceneRenderPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y),
                                                                       blue: Double(clear.z), alpha: 1)
        attachSceneDepth(to: sceneRenderPass, scene: sceneTexture)
        keepScene(sceneRenderPass, scene: sceneTexture, multisampled: multisampledScene)
        // One indirect draw per system, from the records its GPU step writes.
        particleRequests.removeAll(keepingCapacity: true)
        var particleBatches: [(system: ParticleSystemRuntime, material: Bool)] = []
        // Systems are drawn in scene.json order, between the layers around them.
        let orderedSystems = particleSystems.enumerated()
            .sorted { ($0.element.configuration.order, $0.offset) < ($1.element.configuration.order, $1.offset) }
            .map(\.element)
        let particleSignpost = OWESignpost.begin(OWESignpost.render, "updateParticles")
        let particleStepStart = frameStats == nil ? 0 : CACurrentMediaTime()
        // Each visible system's step this frame, for the renderers after its first.
        var steppedInputs: [ObjectIdentifier: ParticleFrameInputs] = [:]
        // Without the GPU simulation (it couldn't be made; logged at init) no particle system draws.
        for system in orderedSystems where particleSimulator != nil {
            let prewarm: [ParticleFrameInputs]
            var inputs: ParticleFrameInputs
            if let simulation = system.simulation {
                // A renderer after a system's first draws the particles that system's step (just
                // before, in the same order) left, with its own orientation; a hidden system's none.
                guard let stepped = steppedInputs[ObjectIdentifier(simulation)] else { continue }
                system.followSimulation()
                prewarm = []
                inputs = stepped
                inputs.drawSizeScale = system.drawSizeScale
                inputs.spriteLinear = system.spriteLinear
            } else {
                // A hidden system (its own `visible` or a parent's) draws nothing; WE clears it once and
                // keeps its time running with emission off (`ParticleFrameInputs.hidden`).
                let objectID = particleObjectID(system)
                if let objectID, !scripts.isVisible(objectID) {
                    // Its emission is off: a script's `emitParticles` while hidden adds nothing later.
                    pendingEmits.removeValue(forKey: objectID)
                    stepHiddenParticles(system, deltaTime: Float(clock.delta), pixelFormat: sceneTexture.pixelFormat)
                    continue
                }
                let script = objectID.flatMap(scripts.object)
                let scripted = script.flatMap(SceneScriptInstanceOverrides.init)
                let emitter = emitterWorld(system.configuration, motion: motion)
                // `starttime`: the system's first frame comes after WE's pre-simulation.
                // WE's engine frame time and frame-rate limit steer drag and the operators' half steps
                // (`ParticleFrameInputs.dragDeltaTime`, `substeps`); the pre-simulation runs in this frame.
                let layerWorld = { [self] (id: String) in emitterImageLayerWorld(id, motion: motion) }
                let layerBones = { [self] (id: String) in emitterImageBones(id) }
                let modelCapsules = { [self] (id: String) in particleCapsules(id, for: system) }
                prewarm = ParticlePrewarm.steps(system).map {
                    ParticleFrameInputs.advance(system, deltaTime: $0, cursor: cursor, emitter: emitter, values: timelines.values,
                                                scripted: scripted,
                                                audio: effectFrame.audio, frameTime: Float(clock.delta),
                                                frameRateLimit: destination.frameRateLimit, layerWorld: layerWorld,
                                                layerBones: layerBones, modelCapsules: modelCapsules)
                }
                // A script's `pause()` holds the system as it is; `stop()` clears it until `play()`.
                let paused = script?.playback == .pause
                inputs = ParticleFrameInputs.advance(system, deltaTime: paused ? 0 : Float(clock.delta), cursor: cursor,
                                                     emitter: emitter, values: timelines.values, scripted: scripted,
                                                     audio: effectFrame.audio,
                                                     frameTime: Float(clock.delta), frameRateLimit: destination.frameRateLimit,
                                                     layerWorld: layerWorld, layerBones: layerBones, modelCapsules: modelCapsules)
                Self.applyScriptPlayback(script?.playback, emitting: objectID.flatMap { pendingEmits.removeValue(forKey: $0) },
                                         to: &inputs)
                steppedInputs[ObjectIdentifier(system)] = inputs
                if !system.imageResamplesDue.isEmpty { resampleEmitterImages(system) }
            }
            // The GPU steps the system and writes whichever records it is drawn from.
            let rendererName = system.configuration.rendererName
            if let simulated = particleMaterials?.prepareSimulated(system, pixelFormat: sceneTexture.pixelFormat,
                                                                   sampleCount: sceneSampleCount,
                                                                   depthFormat: sceneDepthFormat) {
                let kind = ParticleGPUDrawKind.material(simulated.format, rendererName: rendererName)
                for step in prewarm {
                    particleRequests.append(.init(system: system, inputs: step, kind: kind, materialVertexCount: simulated.vertexCount,
                                                  writesRecords: false))
                }
                particleRequests.append(.init(system: system, inputs: inputs, kind: kind,
                                              materialVertexCount: simulated.vertexCount, renderVar: simulated.renderVar))
                particleBatches.append((system, true))
            } else {
                let kind = ParticleGPUDrawKind.fallback(rendererName: rendererName)
                for step in prewarm { particleRequests.append(.init(system: system, inputs: step, kind: kind, writesRecords: false)) }
                particleRequests.append(.init(system: system, inputs: inputs, kind: kind))
                particleBatches.append((system, false))
            }
        }
        particleSignpost.end()
        if frameStats != nil { particleStepMilliseconds = (CACurrentMediaTime() - particleStepStart) * 1000 }
        particleSimulator?.encode(particleRequests, sceneSize: sceneSize, targetSize: drawableSize,
                                  commandBuffer: commandBuffer)
        frameReflection = drawReflection(frame: effectFrame, scene: sceneTexture, draws: draws,
                                         image: { [unowned self] in textFrames[$0]?.frame ?? self.textureFrame(for: self.layers[$0]) },
                                         effectOutputs: dynamicTextures,
                                         batches: particleBatches.map { ($0.system, $0.material) }, commandBuffer: commandBuffer)
        guard var encoder = commandBuffer.makeRenderCommandEncoder(descriptor: sceneRenderPass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        // WE's object loop (docs/models-plan.md §2.4): the layers and models in draw order, each
        // after the particle systems whose key is below its barrier.
        let sequence = drawSequence(batches: particleBatches.map(\.system), forward: effectFrame.camera.forward)
        // A loop, not `map`: the optimised build's specialisation of `map` for this tuple (typed
        // throws, `Never`) checks the error register after a closure that never sets it, and traps
        // ("Never can't be initialized") when the register holds a stale value.
        let unordered = particleBatches
        particleBatches.removeAll(keepingCapacity: true)
        for index in sequence.batchOrder { particleBatches.append(unordered[index]) }
        // Text and the media artwork drawn at the output's backing pixels, after the composite.
        let native = nativeDetailPlan(output, destination: destination, sequence: sequence,
                                      particleBatchCount: particleBatches.count, draws: draws,
                                      compositeOrder: compositeOrder, frame: effectFrame, scene: sceneTexture,
                                      sceneIsOutput: targets.sceneIsOutput)
        let nativeLayers = Set(native.layers)
        for index in native.layers where layers[index].layer.text != nil {
            let entry = layers[index]
            let onScreen = max(worldTransform(entry).axisScale.x, worldTransform(entry).axisScale.y) * native.pixelsPerUnit
            textFrames[index] = layerTextFrame(entry, boxSize: layerBaseSize(entry),
                                               pixelsPerUnit: SceneTextRasterScale.layer(onScreen: onScreen, hasEffects: false))
        }
        var nextParticleBatch = 0
        /// One instanced draw per system, for every system whose key is below `order`. False when the
        /// scene pass couldn't resume after a snapshot.
        func drawParticleBatches(before order: Int) -> Bool {
            var drew = false
            while nextParticleBatch < particleBatches.count, sequence.batchKeys[nextParticleBatch] < order {
                let batch = particleBatches[nextParticleBatch]
                nextParticleBatch += 1
                if batch.material, drawsReducedResolution(batch.system) {
                    // A run of large additive systems draws at half resolution and is added back
                    // in its place (`SceneRenderSettings.reducedResolutionParticles`); addition
                    // commutes, so a system whose half-resolution pipeline still compiles draws
                    // at full resolution right after.
                    var group = [batch.system]
                    while nextParticleBatch < particleBatches.count, sequence.batchKeys[nextParticleBatch] < order,
                          particleBatches[nextParticleBatch].material,
                          drawsReducedResolution(particleBatches[nextParticleBatch].system) {
                        group.append(particleBatches[nextParticleBatch].system)
                        nextParticleBatch += 1
                    }
                    func context(_ system: ParticleSystemRuntime) -> ParticleMaterialRenderer.DrawContext {
                        .init(sceneSize: sceneSize, frame: effectFrame, values: timelines.values,
                              assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                              mipMappedFrameBuffer: mipMappedTarget, shadowAtlas: frameShadowAtlas,
                              placement: particlePlacement(system, camera: effectFrame.camera))
                    }
                    endScenePass(encoder, resumes: true)
                    let reduced = drawReducedResolution(group, scene: sceneTexture, commandBuffer: commandBuffer, context: context)
                    guard let resumed = resumeScenePass(on: sceneTexture, commandBuffer: commandBuffer) else { return false }
                    encoder = resumed
                    if let half = reduced.target {
                        var uniform = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1,
                                                   drawableSize: SIMD2(Float(sceneTexture.width), Float(sceneTexture.height)),
                                                   placement: .stretch)
                        encoder.setRenderPipelineState(scenePassPipelines.addCopy)
                        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
                        encoder.setFragmentTexture(half, index: 0)
                        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                    for system in reduced.left {
                        particleMaterials?.draw(system, encoder: encoder, commandBuffer: commandBuffer, context: context(system))
                    }
                    drew = true
                    continue
                }
                if batch.material {
                    var snapshot: MTLTexture?
                    let placement = particlePlacement(batch.system, camera: effectFrame.camera)
                    if particleMaterials?.readsSceneSnapshot(batch.system) == true {
                        // Refraction reads the scene drawn up to this system (`_rt_FullFrameBuffer`):
                        // all of it, since where the GPU's particles are isn't known here.
                        endScenePass(encoder, resumes: true)
                        snapshot = sceneSnapshot(of: sceneTexture, commandBuffer: commandBuffer)
                        guard let resumed = resumeScenePass(on: sceneTexture, commandBuffer: commandBuffer) else { return false }
                        encoder = resumed
                    }
                    particleMaterials?.draw(batch.system, encoder: encoder, commandBuffer: commandBuffer, context: .init(
                        sceneSize: sceneSize, frame: effectFrame,
                        values: timelines.values,
                        assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                        sceneSnapshot: snapshot, mipMappedFrameBuffer: mipMappedTarget, shadowAtlas: frameShadowAtlas,
                        depth: frameDepth, placement: placement))
                    drew = true
                    continue
                }
                let pipeline = batch.system.configuration.blending == "additive" ? additiveRenderPipeline : renderPipeline
                // The built-in draw has no material: nothing to test against [I].
                frameDepth?.apply(.disabled, to: encoder)
                // The built-in quads the GPU step wrote, counted by its indirect arguments.
                guard let gpu = batch.system.gpu, gpu.isReady, let records = gpu.records,
                      gpu.recordKind?.isFallback == true else { continue }
                // Layer draws rebind index 0 with setVertexBytes, so bind the records per draw.
                encoder.setVertexBuffer(records, offset: 0, index: 0)
                encoder.setFragmentBuffer(records, offset: 0, index: 0)
                encoder.setRenderPipelineState(pipeline)
                encoder.setFragmentTexture(batch.system.fallbackTexture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, indirectBuffer: gpu.control,
                                       indirectBufferOffset: ParticleGPUSystem.Control.fallbackDrawOffset)
                drew = true
            }
            if drew { encoder.setRenderPipelineState(renderPipeline) }
            return true
        }
        sceneCopy = nil
        snapshotSharesMipMappedTarget = mipMappedTarget != nil && SceneMipMappedFrameBuffer.snapshotCanShare(
            layers: layers.lazy.map(\.layer), particleSystems: particleSystems.map(\.configuration),
            reflection: renderSettings.reflection)
        snapshotTracker.reset()
        let targetSize = SIMD2(sceneTexture.width, sceneTexture.height)
        for (item, barrier) in sequence.items {
            let batchesBefore = nextParticleBatch
            guard drawParticleBatches(before: barrier) else { return }
            // Particles cover no rect we track: the snapshot no longer matches anywhere.
            if nextParticleBatch != batchesBefore { snapshotTracker.sceneDrawn(in: nil) }
            guard case .layer(let layerIndex) = item else {
                if case .model(let index) = item {
                    drawModel(index, frame: effectFrame, pixelFormat: sceneTexture.pixelFormat, encoder: encoder,
                              commandBuffer: commandBuffer)
                    snapshotTracker.sceneDrawn(in: nil)
                }
                continue
            }
            let entry = layers[layerIndex]
            // Hidden layers (script `visible = false`) draw nothing, their raw texture included.
            guard let draw = draws[layerIndex] else { continue }
            // Drawn over the output after the composite instead (`drawNativeDetailLayers`).
            if nativeLayers.contains(layerIndex) { continue }
            var layerSnapshot: MTLTexture?
            if entry.layer.readsScene || compositeOrder.inScene.contains(entry.layer.id) {
                // Metal can't sample the attachment it's drawing into: pause the scene pass, run
                // this layer's effects on what's drawn so far (`_rt_FullFrameBuffer`), resume. The
                // effects read the target itself while the pass is paused; only a material that
                // reads the scene from inside the resumed pass needs a copy of it.
                endScenePass(encoder, resumes: true)
                var snapshot: MTLTexture? = sceneTexture
                if entry.layer.imageMaterial?.readsSceneSnapshot == true {
                    // A material or scene input reads the scene under its own quad; an effect anywhere.
                    let needed = entry.layer.effectsReadScene || draw.placement != nil ? nil
                        : SceneSnapshotTracker.pixelRect(of: draw.quad, sceneSize: sceneSize, targetSize: targetSize)
                            ?? SceneSnapshotTracker.Rect.empty
                    snapshot = sceneSnapshot(of: sceneTexture, commandBuffer: commandBuffer, needing: needed)
                    layerSnapshot = snapshot
                }
                let input = entry.layer.sceneInput
                    ? snapshot.flatMap { sceneRegion(of: $0, under: draw.quad, placement: draw.placement, reducedFor: entry.layer,
                                                     commandBuffer: commandBuffer) }
                    : solidEffectInput(entry.layer, commandBuffer: commandBuffer)
                        ?? effectInput(entry, image: textFrames[layerIndex]?.frame ?? textureFrame(for: entry),
                                       commandBuffer: commandBuffer)
                dynamicTextures[layerIndex] = posedEffectOutput(input.flatMap {
                    runEffects(entry, draw: draw, input: $0, snapshot: snapshot, frame: effectFrame, commandBuffer: commandBuffer)
                }, of: entry, camera: effectFrame.camera, commandBuffer: commandBuffer)
                guard let resumed = resumeScenePass(on: sceneTexture, commandBuffer: commandBuffer) else { return }
                encoder = resumed
                // Its composite is what readers drawn after it sample (`_rt_imageLayerComposite_<id>_a`).
                if compositeOrder.sources.contains(entry.layer.id) || models?.compositeLayerIDs.contains(entry.layer.id) == true {
                    layerComposites[entry.layer.id] = dynamicTextures[layerIndex] ?? input
                }
                if !scripts.isVisible(entry.layer.id) { continue }
                // Until its effects are ready the layer has nothing of its own to draw.
                if entry.layer.sceneInput, dynamicTextures[layerIndex] == nil { continue }
            }
            // Drawn below, natively or through its material; through a camera, anywhere.
            if draw.placement != nil {
                snapshotTracker.sceneDrawn(in: nil)
            } else if let drawn = SceneSnapshotTracker.pixelRect(of: draw.quad, sceneSize: sceneSize, targetSize: targetSize) {
                snapshotTracker.sceneDrawn(in: drawn)
            }
            encodeLayer(entry, draw, image: textFrames[layerIndex]?.frame ?? textureFrame(for: entry),
                        effectOutput: dynamicTextures[layerIndex], drawnLastPass: drawnLastPasses[layerIndex],
                        snapshot: layerSnapshot, frame: effectFrame,
                        target: LayerTarget(size: drawableSize, pixelFormat: sceneTexture.pixelFormat,
                                            sampleCount: sceneSampleCount, depth: frameDepth, pipelines: scenePassPipelines),
                        encoder: encoder, commandBuffer: commandBuffer)
        }
        guard drawParticleBatches(before: .max) else { return }
        let nativeImage = { [unowned self] (index: Int) in textFrames[index]?.frame ?? self.textureFrame(for: self.layers[index]) }
        // What reads the finished scene (the bloom, the reflection copy) sees the promoted layers as
        // before: drawn last, where nothing kept in the pass after them reaches. The patch's base is
        // the scene as it was without them.
        var detailBase: MTLTexture?
        if native.feedsScene, !native.layers.isEmpty {
            let fed = feedDetailLayers(native.layers, baseTexels: native.baseTexels, draws: draws, image: nativeImage,
                                       scene: sceneTexture, frame: effectFrame, encoder: &encoder, commandBuffer: commandBuffer)
            guard fed.resumed else { return }
            detailBase = fed.base
        }
        endScenePass(encoder, resumes: keepsScene)

        var stageContext = SceneFrameStageContext(scene: sceneTexture, commandBuffer: commandBuffer, sceneSize: sceneSize,
                                                  frame: effectFrame, settings: renderSettings)
        stageContext.assetTexture = { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) }
        stageContext.sceneDepth = frameDepth == nil ? nil : depthBuffer.texture
        stageContext.shadowAtlas = frameShadowAtlas
        for stage in frameStages { stage.encode(stageContext) }
        // The drawable (F1: taken now, after the frame's work is encoded) or the shared frame.
        // A shared frame that kept its own target for detail layers none of which was promoted is
        // the scene after all, as it would have been (`FrameTargets.deferredPassThrough`).
        let passesThroughNow = targets.deferredPassThrough && native.layers.isEmpty
        if passesThroughNow {
            sharedFrameTarget = nil
            compositesSkipped += 1
        }
        let (descriptor, drawable) = targets.output
            ?? (passesThroughNow ? Self.passThroughOutput(onto: sceneTexture)
                : lateOutput(output, matching: sceneTexture, size: native.sharedSize))
        if let descriptor {
            // What the post-process composites onto: the drawable, or the shared frame.
            let outputTexture = descriptor.colorAttachments[0].texture
            let realDrawableSize = SIMD2<Float>(Float(outputTexture?.width ?? sceneTexture.width),
                                                Float(outputTexture?.height ?? sceneTexture.height))
            // The scene-resolution target goes onto the real drawable, placement applied exactly once.
            let placement = layerUniform(position: sceneSize / 2, size: sceneSize, opacity: 1, drawableSize: realDrawableSize,
                                         placement: destination.placement)
            let postFrame = ScenePostProcess.Frame(
                scene: sceneTexture, output: descriptor, commandBuffer: commandBuffer,
                placement: placement,
                bloom: liveBloom(), extras: appExtras(), settings: renderSettings,
                colorCorrection: colorCorrection(),
                effects: effectGraph, builtins: effectFrame, values: timelines.values, fullDetailScale: fullDetailScale,
                display: displayOutput, sceneIsOutput: targets.sceneIsOutput || passesThroughNow)
            // The promoted layers' patch, over the scene as the composite upscales it without them,
            // made before the post-process (the camera fade may draw onto the scene target).
            var patch: (texture: MTLTexture, rect: SceneSnapshotTracker.Rect)?
            if native.mode == .patch, !native.layers.isEmpty, let rect = native.patch, let outputTexture,
               outputTexture.width == native.outputSize.x, outputTexture.height == native.outputSize.y,
               let base = native.feedsScene ? detailBase : Optional(sceneTexture),
               let texture = detailPatch(native, rect: rect, base: base, baseTexels: native.feedsScene ? native.baseTexels : nil,
                                         sceneTexels: SIMD2(sceneTexture.width, sceneTexture.height), composite: placement,
                                         draws: draws, image: nativeImage, frame: effectFrame, commandBuffer: commandBuffer) {
                patch = (texture, rect)
            }
            postProcess.encode(postFrame)
            if let patch {
                // `combine_ldr`'s sum, then the steps after it, per pixel.
                if let bloom = postProcess.lastBloom?.bloom {
                    addBloom(bloom, to: patch.texture, rect: patch.rect, composite: placement,
                             outputHeight: native.outputSize.y, commandBuffer: commandBuffer)
                }
                postProcess.finishDetailPatch(patch.texture, at: patch.rect, postFrame)
            } else if let outputTexture, !native.layers.isEmpty, !native.feedsScene {
                // Straight over the composite; or, should the patch fail, so they still show.
                drawNativeDetailLayers(native.layers, draws: draws, image: nativeImage, onto: outputTexture,
                                       placement: native.placement, frame: effectFrame, commandBuffer: commandBuffer)
            }
            if let drawable {
                commandBuffer.present(drawable)
            } else {
                sharedFrame = descriptor.colorAttachments[0].texture
            }
        }
        // A video frame's pixel buffer returns to the decoder's pool once released; hold each one
        // this frame sampled until the GPU is done reading it.
        for entry in layers { if case let .video(stream) = entry.layer.source { stream.holdCurrentFrame(until: commandBuffer) } }
        // "Pause when VRAM is exhausted" (`VideoMemoryWatch`): a frame that ran out of memory.
        commandBuffer.addCompletedHandler { buffer in
            guard buffer.status == .error, VideoMemoryWatch.isOutOfMemory(buffer.error) else { return }
            NotificationCenter.default.post(name: .videoMemoryCommandBufferFailed, object: nil)
        }
        commandBuffer.commit()
        lastCommandBuffer = commandBuffer
        if let frameStats { frameStats.finishFrame(sceneStats) }
        // Nothing was compiling when the frame started, nor started or landed while it was
        // encoded: every pass drew.
        if let landedBefore, !pipelinesCompiling, pipelinesLanded == landedBefore, pendingScriptLayers == 0,
           pendingReplacements == 0, textRaster.inFlight == 0 {
            hasCompleteFrame = true
        }
    }

    /// The scene's own numbers for the stats overlay, at the end of a counted frame (WE's
    /// `renderStats`): particles, lights, video textures, the scripts' time and expensive effects.
    private func sceneStats(_ stats: inout SceneFrameStats) {
        for system in particleSystems where system.simulation == nil {
            guard let gpu = system.gpu else { continue }
            stats.particleCount += gpu.completedCount
            stats.particleBytes += gpu.particles?.length ?? 0
        }
        stats.particleMilliseconds = particleStepMilliseconds
        stats.scriptMilliseconds = scripts.wallpaper?.frameTiming.lastMilliseconds ?? 0
        stats.lightCount = lastLightCount
        for entry in layers where scripts.isVisible(entry.layer.id) {
            if case .video = entry.layer.source { stats.videoTextureCount += 1 }
            if puppetsMade, let puppets { stats.clippingMaskPasses += puppets.clippingMaskPasses(entry.layer.id) }
            for effect in entry.layer.weEffects where effect.visible {
                switch effect.performance {
                case .expensive?: stats.expensiveEffects += 1
                case .veryExpensive?: stats.veryExpensiveEffects += 1
                case nil: break
                }
            }
        }
    }

    /// The scene's bloom this frame: `thisScene.bloom`, `bloomstrength` and `bloomthreshold` once a
    /// script set them, else their timelines, else the content's.
    func liveBloom() -> ScenePostProcess.Bloom {
        let scene = scripts.state.scene
        return ScenePostProcess.Bloom(
            enabled: scene.flag(.bloom) ?? bloom.enabled,
            strength: scene.scalar(.bloomstrength) ?? timelines.sceneScalar(.bloomstrength) ?? bloom.strength,
            threshold: scene.scalar(.bloomthreshold) ?? timelines.sceneScalar(.bloomthreshold) ?? bloom.threshold,
            tint: bloom.tint, hdr: liveHDRBloom())
    }

    /// The HDR bloom's `bloomhdr*` this frame: a bound script's, else its timeline's, else the
    /// content's. Whether the scene draws in HDR stays the content's (WE decides it at load).
    private func liveHDRBloom() -> SceneHDRBloomSettings {
        var hdr = bloom.hdr
        hdr.strength = sceneSetting(.bloomhdrstrength) ?? hdr.strength
        hdr.threshold = sceneSetting(.bloomhdrthreshold) ?? hdr.threshold
        hdr.feather = sceneSetting(.bloomhdrfeather) ?? hdr.feather
        hdr.scatter = sceneSetting(.bloomhdrscatter) ?? hdr.scatter
        // An int property: WE's converter truncates (`ToInt32`).
        if let iterations = sceneSetting(.bloomhdriterations), iterations.isFinite, abs(iterations) < 1e9 {
            hdr.iterations = Int(iterations)
        }
        return hdr
    }

    /// The app's own whole-scene adjustments, from this wallpaper's user properties.
    func appExtras() -> ScenePostProcess.AppExtras {
        let services = WallpaperServices.shared
        return ScenePostProcess.AppExtras(bloom: services.userPropertyValue("_owe_bloom", fallback: 1),
                                          saturation: services.userPropertyValue("_owe_saturation", fallback: 1),
                                          hue: services.userPropertyValue("_owe_hue", fallback: 0),
                                          blur: services.userPropertyValue("_owe_blur", fallback: 1))
    }

    /// WE's image filter and colour options, from this wallpaper's user properties.
    func colorCorrection() -> SceneColorCorrectionSettings {
        let services = WallpaperServices.shared
        return SceneColorCorrectionSettings { services.userPropertyString($0.rawValue) }
    }

    /// This frame's lighting (`SceneFrameLighting`), from the objects' live transforms and
    /// visibility, the scripts' scene colours and the user's shadows setting.
    private func frameLighting(eye: SIMD3<Float>, forward: SIMD3<Float>, shake: SIMD2<Float>) -> SceneFrameLighting {
        let scene = scripts.state.scene
        var frame = SceneFrameLighting.frame(lighting, input: SceneFrameLightingInput(

            local: { [unowned self] id in self.liveLocal(id) ?? self.transforms.nodes[id]?.local },
            parentWorld: { [unowned self] id in self.transforms.parentWorld(of: id) { self.liveLocal($0) } },
            isVisible: { [unowned self] id in self.scripts.isVisible(id) },
            world3D: isPerspective ? { [unowned self] id in self.world3D(id, in: self.spatial.transforms) } : nil,
            sceneColor: { scene.vector3($0) },
            live: { [unowned self] object in
                object.live(script: self.scripts.object(object.id), animation: self.timelines.object(object.id),
                            timeline: { self.timelines.objectField(object.id, $0) })
            },
            shadows: renderSettings.shadows != .disabled, shadowQuality: renderSettings.shadows.level,
            reducedShadowMaps: renderSettings.cheaperShadows,
            orthographic: !isPerspective, shadowAtlasExtent: shadowPass?.atlas.extent ?? .zero, cameraShake: shake,
            eyePosition: eye, viewForward: forward, zoom: frameZoom))
        frame.fog = frame.fog.live(number: { [unowned self] in self.sceneSetting($0) }, color: { scene.vector3($0) })
        if !loggedFogToggle, frame.fog.distance != lighting.settings.fog.distance || frame.fog.height != lighting.settings.fog.height {
            loggedFogToggle = true
            OWELog.error(.scene, "A script turned the scene's fog on or off: the materials keep the fog combos they were built with, so only its colours, ranges and densities follow the script")
        }
        return frame

    }

    /// This frame's `_rt_shadowAtlas` (docs/models-plan.md §2.10): the lighting's shadow maps
    /// drawn with the visible model objects that cast, before the scene pass reads them, or the
    /// cleared stand-in without maps.
    private func drawShadows(frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let shadowPass, let models else { return nil }
        let casters = spatial.models.filter { scripts.isVisible($0.id) && SceneShadowPass.castsShadow($0) }
            .map { SceneShadowPass.Caster(model: $0, world: drawnWorld3D($0.id)) }
        return shadowPass.encode(frame.lighting.shadows, casters: casters, models: models, frame: frame, values: timelines.values,
                                 assetTexture: { [unowned self] key, source in self.effectAssetTexture(key: key, source: source) },
                                 commandBuffer: commandBuffer)
    }

    /// Compiles landed so far in every renderer that compiles off the render thread
    /// (`pipelinesCompiling`'s).
    private var pipelinesLanded: Int {
        // Typed terms: one chained expression is past Swift 6.2's type-check budget.
        let materials: Int = (imageMaterials?.pipelinesLanded ?? 0) &+ (particleMaterials?.pipelinesLanded ?? 0)
        let geometry: Int = (modelDrawing?.pipelinesLanded ?? 0) &+ (shadowPass?.pipelinesLanded ?? 0)
        let puppetLanded: Int = puppetsMade ? (puppets?.pipelinesLanded ?? 0) &+ (puppets?.channels.pipelinesLanded ?? 0) : 0
        let volume: Int = volumetrics?.pipelines?.pipelinesLanded ?? 0
        return (effectGraph?.pipelinesLanded ?? 0) &+ materials &+ geometry &+ puppetLanded &+ volume
    }

    /// Whether any pipeline is still compiling off the render thread. A puppet's mesh pipeline
    /// counts too: until it lands the puppet's image stays transparent (`ScenePuppetRenderer`);
    /// so do its texture channels', the shadow casters' (no shadow until theirs land) and the
    /// volumetrics' (no volume).
    var pipelinesCompiling: Bool {
        let puppetPending: Bool = puppetsMade
            && (puppets?.hasPendingPipelines == true || puppets?.channels.hasPendingPipelines == true)
        let materials: Bool = imageMaterials?.hasPendingPipelines == true || particleMaterials?.hasPendingPipelines == true
        let geometry: Bool = modelDrawing?.hasPendingPipelines == true || shadowPass?.hasPendingPipelines == true
        let volume: Bool = volumetrics?.pipelines?.hasPendingPipelines == true
        return hasPendingEffectPipelines || materials || geometry || puppetPending || volume
    }

    /// The unquantised pixels per unit that sizes the scene target to `drawable` when the scene is
    /// a single effect-less video filling it at the same aspect; nil otherwise.
    private func videoOnlyPixelsPerUnit(_ drawable: SIMD2<Float>) -> Float? {
        guard layers.count == 1, case .video = layers[0].layer.source, layers[0].layer.weEffects.isEmpty,
              particleSystems.isEmpty, spatial.models.isEmpty, !scripts.isRunning,
              sceneSize.x > 0, sceneSize.y > 0, drawable.x > 0, drawable.y > 0 else { return nil }
        let exact = drawable.x / sceneSize.x
        guard abs(sceneSize.y * exact - drawable.y) < 0.5,
              max(drawable.x, drawable.y) <= SceneRenderResolution.maximumTextureDimension else { return nil }
        return exact
    }

    /// Hands this frame's inputs to the layer analysis, which marks the layers they change dirty.
    private func analyseLayers(effectFrame: BuiltinFrameContext, motion: CameraMotion, drawableSize: SIMD2<Float>) {
        guard let layerAnalysis else { return }
        var inputs = SceneLayerFrameInputs()
        inputs.time = effectFrame.time
        inputs.pointer = effectFrame.pointer
        inputs.parallax = effectFrame.parallax
        inputs.parallaxActive = motion.parallax != nil
        inputs.shake = motion.shake
        inputs.cameraShake = motion.cameraShake
        inputs.audio = effectFrame.audio
        inputs.audioLevel = motion.audioLevel
        // System textures (now-playing artwork) keep following the clock; a video only its frames.
        if mediaTextures != nil && effectFrame.time != analysedTime
            || layers.contains(where: { if case let .video(stream) = $0.layer.source { stream.hasNewFrame } else { false } }) {
            videoRevision &+= 1
        }
        analysedTime = effectFrame.time
        inputs.videoRevision = videoRevision
        inputs.userPropertiesRevision = WallpaperServices.shared.propertyService.revision
        inputs.scripts = scripts.state
        inputs.animatedSites = animations?.sites ?? []
        let shape = (layers: layers.count, target: drawableSize)
        // A layer, effect or post-process whose pipeline is still compiling draws another way until
        // it lands; nothing the analysis tracks says when.
        // A compile can also start and land between two frames, unseen by `warming`.
        let warming = pipelinesCompiling
        let landed = pipelinesLanded
        inputs.sceneChanged = shape.layers != analysedShape.layers || shape.target != analysedShape.target
            || warming || analysedWarmUp || landed != analysedLanded || textRaster.hasFinished
            || scripts.userVisibilityRevision != analysedUserVisibility
            || editorLive.revision != analysedEditorRevision
        analysedUserVisibility = scripts.userVisibilityRevision
        analysedEditorRevision = editorLive.revision
        analysedLanded = landed
        analysedShape = shape
        analysedWarmUp = warming
        layerAnalysis.update(inputs)
    }

    /// Whether this frame is drawn (`FramePacing`); called once the analysis has seen its inputs.
    private func paceFrame(_ frame: BuiltinFrameContext, at now: CFTimeInterval) -> Bool {
        let parallaxMoved = frame.parallax != pacedParallax
        pacedParallax = frame.parallax
        guard let analysis = layerAnalysis else { return framePacing.record(.smooth, at: now) }
        // Models pose every frame (the analysis counts the scene's own as animated stages); one a
        // script created after the load counts the same.
        if !spatial.models.isEmpty { return framePacing.record(.smooth, at: now) || !skipsIdleFrames }
        var particlesLive = false, particlesFollowCursor = false
        for system in particleSystems where particleObjectID(system).map({ scripts.isVisible($0) }) ?? true {
            particlesLive = true
            if system.configuration.controlPoints.contains(where: \.followsCursor) { particlesFollowCursor = true; break }
        }
        let inputs = FrameDemandInputs(analysis: analysis, pointerMoved: frame.pointer != frame.pointerLast,
                                       parallaxMoved: parallaxMoved, particlesLive: particlesLive,
                                       particlesFollowCursor: particlesFollowCursor)
        return framePacing.record(framePacing.classify(inputs), at: now) || !skipsIdleFrames
    }

    /// The cursor in scene units, mapped through the placement of the display it is on, or nil
    /// while it is on none of this scene's displays.
    private func sceneCursor(_ viewports: [SceneViewport]) -> SIMD2<Float>? {
        for viewport in viewports {
            guard let drawablePoint = viewport.cursorPixels else { continue }
            return ScenePlacementScale.scenePoint(drawablePoint: drawablePoint, placement: placement, sceneSize: sceneSize,
                                                  drawableSize: viewport.drawableSize, pixelsPerPoint: viewport.pixelsPerPoint)
        }
        return nil
    }
}
