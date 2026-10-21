import Metal
import simd

/// What follows the scene pass, once per frame (docs/lighting-plan.md §2.6 "Frame order", steps
/// 3–8): WE copies the frame to `_rt_FullFrameBuffer`, runs its bloom (LDR or HDR) and combine,
/// then colour correction and the camera fade, and presents.
///
/// Here the finished scene target is `_rt_FullFrameBuffer` (it isn't drawn to again). Step 5 is
/// WE's LDR bloom (`SceneBloomChain`), gated like WE's by the scene's live `bloom` and the user's
/// post-processing setting; in a content drawn in HDR it is the HDR chain (`SceneHDRChain`), or
/// `combine_srgb` while bloom doesn't run. Step 6 is WE's colour correction (`SceneColorCorrection`)
/// when the user's image filter or colour options aren't identity. Step 7 is the camera fade
/// (`SceneCameraFade`) while a camera path starts or ends. The composite then puts the frame on the
/// drawable at the user's placement with the app's own adjustments (`AppExtras`), which aren't WE's.
final class ScenePostProcess {
    /// The scene's bloom this frame, scripts' and timelines' values included.
    struct Bloom: Equatable {
        var enabled: Bool
        var strength: Float
        var threshold: Float
        var tint: SIMD3<Float>
        var hdr = SceneHDRBloomSettings()
    }

    /// The app's own adjustments, not WE's (the `_owe_bloom`, `_owe_saturation`, `_owe_hue` and
    /// `_owe_blur` user properties); these defaults change nothing.
    struct AppExtras: Equatable {
        /// Multiplies WE's bloom strength; 1 is WE's bloom. A scene without bloom has none to scale.
        var bloom: Float = 1
        var saturation: Float = 1
        var hue: Float = 0
        var blur: Float = 1
    }

    struct Frame {
        /// The finished scene target (`_rt_FullFrameBuffer`).
        var scene: MTLTexture
        /// The drawable's pass.
        var output: MTLRenderPassDescriptor
        var commandBuffer: MTLCommandBuffer
        /// The scene's quad on the drawable at the user's placement, as `sceneVertex` reads it.
        var placement: LayerUniform
        var bloom: Bloom
        var extras: AppExtras
        var settings: SceneRenderSettings
        /// The wallpaper's image filter and colour options (WE's `wcc_*`/`wec_*` properties).
        var colorCorrection = SceneColorCorrectionSettings()
        /// Runs WE's post-processing passes; nil puts the frame on the drawable without them.
        var effects: EffectGraphRenderer?
        /// This frame's built-in inputs and bound values, for those passes.
        var builtins = BuiltinFrameContext()
        var values: SceneValueContext = LiveSceneValueContext()
        /// How much larger full detail would draw `scene` (`GSSceneDetail.matchDisplay` on a
        /// display smaller than the scene): the bloom steps in texels of that size and runs its
        /// levels, so it spans the same part of the frame as at full detail.
        var fullDetailScale: Float = 1
        /// How the frame reaches the display: display HDR's EDR output combines with WE's display
        /// HDR combine and keeps linear values above 1 up to the drawable (`SceneDisplayOutput`).
        var display = SceneDisplayOutput.standard
        /// The scene was drawn straight into the output (`passesThrough`, S2): nothing composites.
        var sceneIsOutput = false

        /// The size the bloom's texel steps and HDR levels are counted in.
        var bloomReferenceSize: SIMD2<Float> {
            (SIMD2(Float(scene.width), Float(scene.height)) * max(fullDetailScale, 1)).rounded(.toNearestOrAwayFromZero)
        }
    }

    /// One frame's bloom: what went in, what came out and the constants of pass 1.
    struct BloomRecord {
        var frame: MTLTexture
        var bloomed: MTLTexture
        var strength: Float
        var threshold: Float
        var tint: SIMD3<Float>
        /// `_rt_Bloom`, which pass 4 (`combine_ldr`) added to the frame.
        var bloom: MTLTexture? = nil
    }

    /// The last frame's bloom, nil when it didn't run (tests, diagnostics).
    private(set) var lastBloom: BloomRecord?

    /// One HDR frame's combine: the float frame, the sRGB output, the levels the bloom ran (nil
    /// for `combine_srgb` alone) and its constants.
    struct HDRRecord {
        var frame: MTLTexture
        var combined: MTLTexture
        var levels: Int?
        var constants: SceneHDRChain.Constants
    }

    /// The last HDR frame's combine, nil when the content isn't drawn in HDR or it didn't run.
    private(set) var lastHDR: HDRRecord?

    /// The last frame's colour correction: what went in and what came out; nil when it didn't run.
    private(set) var lastColorCorrection: (frame: MTLTexture, corrected: MTLTexture)?

    /// The composite's pipelines by drawable format: the renderer's, and the EDR one made on
    /// first use (`compositeDescriptor`).
    private var compositePipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let compositeDescriptor: MTLRenderPipelineDescriptor
    private let device: MTLDevice
    /// The content's LDR bloom chain; nil without a shader toolchain.
    private var bloomChain: SceneBloomChain?
    /// The content's HDR chain, when it draws in HDR (`SceneMetalContent.hdrChain`).
    private var hdrChain: SceneHDRChain?
    /// WE's colour correction pass; nil without a shader toolchain.
    private var colorCorrection: SceneColorCorrection?
    /// WE's camera fade, for a scene with camera paths.
    private(set) var cameraFade: SceneCameraFade?
    /// The colour correction's targets are held by the effect graph.
    private var holdsColorCorrection = false
    /// The detail patch's colour correction targets are held (`finishDetailPatch`), and whether a
    /// patch was corrected since the last frame.
    private var holdsPatchColorCorrection = false
    private var correctedPatch = false
    /// Frames corrected so far: its input changes every frame while the texture stays.
    private var correctedFrames: UInt64 = 0
    /// The content draws in HDR: float targets, `HDR=1`, the HDR chain (`SceneEngineCombos.hdr`).
    private(set) var drawsHDR = false
    /// The HDR frame holds a HDR video's linear light (`SceneMetalContent.videoHDR`).
    private var videoHDR = false
    /// Frames bloomed so far: the chain's input changes every frame while its texture stays.
    private var bloomFrames: UInt64 = 0
    /// The chain whose targets the effect graph holds (released when it stops running).
    private var heldChain: String?
    /// The HDR combine's output as the composite reads it (`SceneHDRChain.encodedView`), by output.
    private var encodedView: (output: ObjectIdentifier, view: MTLTexture)?
    /// The composite pass failed once already (it is logged once, not every frame).
    private var reportedEncodeFailure = false

    /// `layerDescriptor` is the scene's layer pipeline, whose functions and output format the
    /// composite shares. Nil when a pipeline can't be made.
    init?(device: MTLDevice, layerDescriptor: MTLRenderPipelineDescriptor) {
        self.device = device
        compositeDescriptor = SceneComposite.pipelineDescriptor(basedOn: layerDescriptor)
        do {
            compositePipelines[compositeDescriptor.colorAttachments[0].pixelFormat] =
                try device.makeRenderPipelineState(descriptor: compositeDescriptor)
        } catch {
            OWELog.error(.scene, "The scene composite pipeline can't be made: \(error)")
            return nil
        }
    }

    /// A new content (a new scene or a rebuild).
    func setContent(_ content: SceneMetalContent) {
        bloomChain = content.bloomChain
        hdrChain = content.hdrChain
        colorCorrection = content.colorCorrection
        cameraFade = content.cameraFade
        drawsHDR = content.engineCombos.hdr
        videoHDR = content.videoHDR
        // The last frame's textures (a full-size float frame and combine at worst) go with it.
        encodedView = nil
        lastBloom = nil
        lastHDR = nil
        lastColorCorrection = nil
    }

    /// Whether the HDR combine's output view is held (tests: it mustn't outlive HDR content).
    var holdsHDROutput: Bool { encodedView != nil }

    /// Encodes everything from the scene target to the drawable. The caller presents and commits.
    func encode(_ frame: Frame) {
        // The detail patch's correction targets go once a frame passes without one.
        if holdsPatchColorCorrection, !correctedPatch, let effects = frame.effects {
            effects.releaseLayer(SceneColorCorrection.patchStateID)
            holdsPatchColorCorrection = false
        }
        correctedPatch = false
        // Step 5: the bloom and its combine.
        let combined = (drawsHDR ? combinedHDR(frame) : bloomed(frame)) ?? frame.scene
        // Step 6: WE's colour correction. Step 7: the camera fade, over what the frame shows.
        let finished = colorCorrected(combined, frame) ?? combined
        cameraFade?.encode(on: finished, alpha: frame.builtins.camera.fade, builtins: frame.builtins,
                           values: frame.values, commandBuffer: frame.commandBuffer)
        // The scene already is the output (S2); `passesThrough` held, so nothing above changed it.
        if frame.sceneIsOutput { return }
        composite(finished, frame)
    }

    /// Whether this frame's post-process would leave the scene as it is and the composite would
    /// copy it 1:1 (S2): LDR, WE's bloom not running, colour correction identity, the app's
    /// adjustments at their defaults, and the scene target the output's size with a placement that
    /// fills it exactly. The camera fade doesn't count: it draws onto the finished frame in place.
    /// The caller then draws the scene straight into the output and the composite is skipped.
    func passesThrough(bloom: Bloom, extras: AppExtras, settings: SceneRenderSettings,
                       colorCorrection: SceneColorCorrectionSettings, display: SceneDisplayOutput,
                       sceneSize: SIMD2<Int>, outputSize: SIMD2<Int>, placement: LayerUniform) -> Bool {
        guard !drawsHDR, !display.isExtended, !Self.runsBloom(bloom, settings: settings), colorCorrection.isIdentity,
              sceneSize == outputSize else { return false }
        return Self.compositeCopies(Self.compositeUniform(placement, extras: extras), size: outputSize)
    }

    /// How this frame's post-process lets text and the media artwork be drawn at the output's pixels
    /// (`SceneNativeDetailLayers`): nil when a step works on more than the pixel it writes, or
    /// converts the frame (HDR, EDR, the app's blur); `.direct` when it only places the scene, so a
    /// layer drawn over the output after the composite looks as it would drawn into the scene; else
    /// `.patch`, every step per pixel (the bloom's combine, colour correction, the camera fade, the
    /// app's saturation and hue), which `finishDetailPatch` runs on the layers' patch.
    func detailMode(bloom: Bloom, extras: AppExtras, settings: SceneRenderSettings,
                    colorCorrection: SceneColorCorrectionSettings, display: SceneDisplayOutput,
                    fade: Float) -> SceneNativeDetailLayers.Mode? {
        guard !drawsHDR, !display.isExtended, extras.blur <= 1 else { return nil }
        let perPixel = Self.runsBloom(bloom, settings: settings) || !colorCorrection.isIdentity
            || (fade > 0 && cameraFade != nil) || extras.saturation != 1 || abs(extras.hue) > 0.0001
        return perPixel ? .patch : .direct
    }

    /// Whether the composite drawn with `uniform` onto `size` pixels from a scene target of that
    /// size is a copy: a quad exactly covering the output (to a thousandth of a pixel, so every
    /// fragment samples its texel's centre), unrotated, whole-texture UVs and every adjustment
    /// `sceneFragment` applies at its identity.
    static func compositeCopies(_ uniform: LayerUniform, size: SIMD2<Int>) -> Bool {
        let output = SIMD2<Float>(Float(size.x), Float(size.y))
        let tolerance: Float = 1e-3
        return uniform.sceneSize == output
            && simd_reduce_max(simd_abs(uniform.position - output / 2)) < tolerance
            && simd_reduce_max(simd_abs(uniform.size - output)) < tolerance
            && uniform.rotation == 0 && uniform.quadAxisX == .zero && uniform.quadAxisY == .zero
            && uniform.particleShape <= 0.5
            && uniform.uvOrigin == .zero && uniform.uvAxisX == SIMD2(1, 0) && uniform.uvAxisY == SIMD2(0, 1)
            && uniform.transform == SIMD4(0, 0, 0, 1) && uniform.transformScaleY == 1
            && uniform.blur <= 0
            && uniform.effects.x == 1 && uniform.effects.y == 1 && uniform.effects.z == 1
            && uniform.colorEffects.x == 0 && uniform.colorEffects.y == 1 && abs(uniform.colorEffects.z) <= 0.0001
            && uniform.color.x == 1 && uniform.color.y == 1 && uniform.color.z == 1
    }

    /// Whether WE runs its bloom this frame (`0x140180a41`): the post-processing setting allows it
    /// (render flag 0x40) and the scene's live `bloom` is on.
    static func runsBloom(_ bloom: Bloom, settings: SceneRenderSettings) -> Bool {
        settings.postProcessing.allowsBloom && bloom.enabled
    }

    /// `g_BloomStrength`: the scene's, scaled by the app's bloom slider (1 = WE's).
    static func bloomStrength(_ bloom: Bloom, extras: AppExtras) -> Float {
        bloom.strength * max(extras.bloom, 0)
    }

    /// Makes `chain` (a state id, nil for none) the one whose targets the effect graph holds.
    private func hold(_ chain: String?, in effects: EffectGraphRenderer) {
        guard heldChain != chain else { return }
        if let heldChain { effects.releaseLayer(heldChain) }
        heldChain = chain
    }

    /// The frame with WE's LDR bloom; nil when bloom doesn't run or its passes aren't ready.
    private func bloomed(_ frame: Frame) -> MTLTexture? {
        lastBloom = nil
        lastHDR = nil
        encodedView = nil
        guard let effects = frame.effects else { return nil }
        guard Self.runsBloom(frame.bloom, settings: frame.settings), let bloomChain else {
            hold(nil, in: effects)
            return nil
        }
        hold(SceneBloomChain.stateID, in: effects)
        bloomFrames &+= 1
        let strength = Self.bloomStrength(frame.bloom, extras: frame.extras)
        guard let bloomed = bloomChain.encode(on: frame.scene, strength: strength, threshold: frame.bloom.threshold,
                                              tint: frame.bloom.tint, effects: effects, builtins: frame.builtins,
                                              values: frame.values, frameIndex: bloomFrames,
                                              referenceSize: frame.bloomReferenceSize,
                                              commandBuffer: frame.commandBuffer) else { return nil }
        lastBloom = BloomRecord(frame: frame.scene, bloomed: bloomed, strength: strength,
                                threshold: frame.bloom.threshold, tint: frame.bloom.tint,
                                bloom: effects.fboTexture("_rt_Bloom", effect: 0, layer: SceneBloomChain.stateID))
        return bloomed
    }

    /// The levels WE's HDR bloom runs on `frame` this frame, or nil when bloom doesn't run and
    /// the frame takes `combine_srgb` (`0x140180a41`, `0x140184058`).
    static func hdrLevels(_ frame: Frame) -> Int? {
        guard runsBloom(frame.bloom, settings: frame.settings) else { return nil }
        let reference = frame.bloomReferenceSize
        return SceneHDRChain.runLevels(width: Int(reference.x), height: Int(reference.y),
                                       iterations: frame.bloom.hdr.iterations)
    }

    /// A HDR frame through WE's HDR bloom and combine, or `combine_srgb` while bloom doesn't run, as
    /// the composite reads it; nil when the passes aren't ready (the frame is composited as it is).
    private func combinedHDR(_ frame: Frame) -> MTLTexture? {
        lastBloom = nil
        lastHDR = nil
        guard let effects = frame.effects else { return nil }
        guard let hdrChain else {
            hold(nil, in: effects)
            return nil
        }
        hold(SceneHDRChain.stateID, in: effects)
        bloomFrames &+= 1
        let levels = Self.hdrLevels(frame)
        let constants = SceneHDRChain.Constants(frame.bloom.hdr, levels: levels ?? 1, tint: frame.bloom.tint,
                                                strengthScale: max(frame.extras.bloom, 0))
        guard let combined = hdrChain.encode(on: frame.scene, levels: levels, constants: constants, effects: effects,
                                             builtins: frame.builtins, values: frame.values, frameIndex: bloomFrames,
                                             referenceSize: frame.bloomReferenceSize, displayHDR: frame.display.renderVar,
                                             videoHDR: videoHDR, commandBuffer: frame.commandBuffer) else { return nil }
        lastHDR = HDRRecord(frame: frame.scene, combined: combined, levels: levels, constants: constants)
        if encodedView?.output != ObjectIdentifier(combined) {
            encodedView = SceneHDRChain.encodedView(of: combined).map { (ObjectIdentifier(combined), $0) }
        }
        return encodedView?.view
    }

    /// Step 6: `frame` through WE's `ccsimple`, or nil when the settings are identity (WE makes no
    /// pass) or it isn't ready. A HDR frame is corrected as the composite shows it.
    private func colorCorrected(_ combined: MTLTexture, _ frame: Frame) -> MTLTexture? {
        lastColorCorrection = nil
        guard let effects = frame.effects else { return nil }
        guard !frame.colorCorrection.isIdentity, let colorCorrection else {
            if holdsColorCorrection {
                effects.releaseLayer(SceneColorCorrection.stateID)
                holdsColorCorrection = false
            }
            return nil
        }
        holdsColorCorrection = true
        correctedFrames &+= 1
        // The EDR frame keeps its values above 1 through it.
        guard let corrected = colorCorrection.encode(on: combined, settings: frame.colorCorrection, effects: effects,
                                                     builtins: frame.builtins, values: frame.values,
                                                     frameIndex: correctedFrames,
                                                     format: frame.display.isExtended ? SceneDisplayOutput.extendedPixelFormat
                                                         : .rgba8Unorm,
                                                     commandBuffer: frame.commandBuffer) else { return nil }
        lastColorCorrection = (combined, corrected)
        return corrected
    }

    /// Step 8: `finished` on the drawable at the user's placement, with the app's adjustments.
    private func composite(_ finished: MTLTexture, _ frame: Frame) {
        guard let pipeline = compositePipeline(for: frame.output.colorAttachments[0].texture?.pixelFormat
                                                    ?? compositeDescriptor.colorAttachments[0].pixelFormat),
              let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: frame.output) else {
            if !reportedEncodeFailure {
                OWELog.error(.scene, "The scene composite pass can't be encoded; the drawable keeps its last frame")
                reportedEncodeFailure = true
            }
            return
        }
        encoder.setRenderPipelineState(pipeline)
        var uniform = Self.compositeUniform(frame.placement, extras: frame.extras)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(finished, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Runs this frame's steps after the bloom on `patch`, the output's pixels `rect` (origin at the
    /// top left) as the upscaled scene with the detail layers drawn in and `_rt_Bloom` added
    /// (`SceneNativeDetailLayers`), and composites it over that part of the output. Call after
    /// `encode(frame)`: the patch takes the steps the frame took, WE's colour correction (when it
    /// ran) and camera fade, then the composite's adjustments, each per pixel, so away from the
    /// detail layers it shows what the composite put there.
    func finishDetailPatch(_ patch: MTLTexture, at rect: SceneSnapshotTracker.Rect, _ frame: Frame) {
        var finished = patch
        if lastColorCorrection != nil, let effects = frame.effects, let colorCorrection {
            holdsPatchColorCorrection = true
            correctedPatch = true
            // Its own targets: the patch isn't the frame's size.
            finished = colorCorrection.encode(on: patch, settings: frame.colorCorrection, effects: effects,
                                              builtins: frame.builtins, values: frame.values, frameIndex: correctedFrames,
                                              stateID: SceneColorCorrection.patchStateID,
                                              commandBuffer: frame.commandBuffer) ?? patch
        }
        if let cameraFade, cameraFade.lastFade != nil {
            cameraFade.encode(on: finished, alpha: frame.builtins.camera.fade, builtins: frame.builtins,
                              values: frame.values, records: false, commandBuffer: frame.commandBuffer)
        }
        guard let output = frame.output.colorAttachments[0].texture,
              let pipeline = compositePipeline(for: output.pixelFormat) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = frame.commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "detail patch"
        encoder.setRenderPipelineState(pipeline)
        // The patch's pixels onto the output's, 1:1, with the composite's adjustments.
        var uniform = Self.compositeUniform(frame.placement, extras: frame.extras)
        uniform.sceneSize = SIMD2(Float(output.width), Float(output.height))
        uniform.size = SIMD2(Float(rect.width), Float(rect.height))
        uniform.position = SIMD2(Float(rect.x) + uniform.size.x / 2, Float(output.height - rect.maxY) + uniform.size.y / 2)
        uniform.rotation = 0
        uniform.quadAxisX = .zero
        uniform.quadAxisY = .zero
        uniform.uvOrigin = .zero
        uniform.uvAxisX = SIMD2(1, 0)
        uniform.uvAxisY = SIMD2(0, 1)
        encoder.setVertexBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentBytes(&uniform, length: MemoryLayout<LayerUniform>.stride, index: 0)
        encoder.setFragmentTexture(finished, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// The composite's pipeline drawing into `format`; nil (the composite is skipped, logged) when it
    /// can't be made.
    private func compositePipeline(for format: MTLPixelFormat) -> MTLRenderPipelineState? {
        if let pipeline = compositePipelines[format] { return pipeline }
        let descriptor = compositeDescriptor.copy() as! MTLRenderPipelineDescriptor
        descriptor.colorAttachments[0].pixelFormat = format
        do {
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            compositePipelines[format] = pipeline
            return pipeline
        } catch {
            OWELog.error(.scene, "The scene composite pipeline for \(format) can't be made: \(error)")
            return nil
        }
    }

    /// The composite's uniform: `placement` with the app's adjustments.
    static func compositeUniform(_ placement: LayerUniform, extras: AppExtras) -> LayerUniform {
        var uniform = placement
        // The app's saturation and hue are linear in colour, so on the composite they equal applying
        // them to every layer, and layers keep drawing through their WE materials.
        uniform.effects = SIMD4<Float>(1, 1, extras.saturation, 0)
        uniform.colorEffects.z = extras.hue
        // "_owe_blur" defaults to 1 (no extra blur); raising it above 1 blurs the whole composited scene,
        // independent of any per-layer material blur, so the slider is guaranteed to have an effect.
        uniform.blur = max(extras.blur - 1, 0) * 4
        return uniform
    }
}
