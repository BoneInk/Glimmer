import Metal
import simd

/// WE's volumetric lights (`wallpaper64.exe` 0x140196ce0 per light, 0x140198d00 to finish;
/// docs/lighting-plan.md §2.8), the first of the `SceneFrameStages`.
///
/// For each visible light that casts volumetrics, in scene order:
/// 1. `_rt_volumetricsBack` ← the scene's depth (the target's copy, vt+0x8).
/// 2. `_rt_volumetricsSingle` (the light buffer's size, depth only) is cleared and
///    `volumetrics_back` draws the far faces of the light's volume into it.
/// 3. `volumetrics_front` (or `volumetrics_fullscreen` when the camera is inside the volume)
///    ray-marches from the near faces to the nearer of the scene and the far faces, adding into
///    `_rt_volumetricsLightBuffer`, which the first light of a run clears to (0, 0, 0, 1).
///
/// Then, below quality 3, `volumetrics_blur_h` and `_v` blur the light buffer through
/// `_rt_volumetricsLightBufferB`, and `volumetrics_combine` adds it to the frame.
///
/// **Where it runs.** WE draws a light's volume at the light's place in the object list and
/// combines a run of consecutive lights when the next object that isn't a light draws, or at the
/// end of the list (0x14018ade4…0x14018b21e). Here the stage runs once the scene pass has ended:
/// the same as WE's when the volumetric lights come after every drawn object (Hinata's does), while
/// objects WE would draw after a light's run are under its volumetrics here. It runs before the
/// `_rt_MipMappedFrameBuffer` copy, which in WE follows the object loop.
///
/// **Camera and depth.** The volumes are drawn through the frame's scene camera
/// (`BuiltinFrameContext.camera`), whose depth is reversed as WE's is everywhere: 1 at the near
/// plane, 0 at the far one. The passes get `REVERSEDEPTH` (`SceneEngineCombos`), the far faces go
/// into `_rt_volumetricsSingle` cleared to 0 and compared GREATER, and the volume meshes put their
/// near and far planes at clip depths 1 and 0 (`SceneVolumeMesh`). The scene pass has no depth
/// buffer yet (area 6), so `_rt_volumetricsBack` holds the far depth, 0;
/// `SceneFrameStageContext.sceneDepth` takes the scene's depth once it has one. WE copies it for
/// every light; nothing between them writes depth, so it is copied once a frame. The shaders read
/// clip depth, D3D's rows (`volumetricsClipDepth`), from both targets.
final class SceneVolumetrics: SceneFrameStage {
    /// What the last frame drew (tests, diagnostics).
    struct Record {
        /// The lights drawn, in order, and whether each drew fullscreen.
        var lights: [(id: String, fullscreen: Bool)]
        var quality: Int
        /// The light buffer as combined (blurred when the quality blurs).
        var lightBuffer: MTLTexture
    }

    private(set) var lastRecord: Record?
    private(set) var plan: SceneVolumetricsPlan?
    let pipelines: SceneVolumetricsPipelines?
    private let device: MTLDevice
    private var targets: Targets?
    /// The far clip depth as one texel, `_rt_volumetricsBack` without a scene depth.
    private var farBack: MTLTexture?
    private var reportedFailure = false
    /// `_rt_shadowAtlas`'s comparison sampler, for a shadow-casting light (`SHADOW`).
    private lazy var shadowSampler = SceneShadowAtlas.makeSampler(device: device)

    private struct Targets {
        let sceneSize: SIMD2<Int>
        let divisor: Int
        let format: MTLPixelFormat
        let lightBuffer: MTLTexture
        let lightBufferB: MTLTexture?
        /// `_rt_volumetricsSingle` as drawn, and as the shader reads it.
        let singleDepth: MTLTexture
        let single: MTLTexture
        /// `_rt_volumetricsBack` at full size, made once a scene depth is given.
        var back: MTLTexture?
    }

    init(device: MTLDevice) {
        self.device = device
        pipelines = SceneVolumetricsPipelines(device: device)
    }

    /// The bytes of the targets the stage holds (diagnostics, test-risks LR10).
    var residentBytes: Int {
        guard let targets else { return farBack?.allocatedSize ?? 0 }
        return [targets.lightBuffer, targets.lightBufferB, targets.singleDepth, targets.single, targets.back, farBack]
            .reduce(0) { $0 + ($1?.allocatedSize ?? 0) }
    }

    func setContent(_ content: SceneMetalContent) {
        plan = content.volumetrics
        lastRecord = nil
        if plan == nil { targets = nil }
        if let plan {
            for skipped in plan.skipped {
                OWELog.info(.scene, "Light \(skipped.id) casts volumetrics but isn't drawn: \(skipped.reason)")
            }
        }
    }

    /// Replaces the plan without a content (tests).
    func setPlan(_ plan: SceneVolumetricsPlan?) {
        self.plan = plan
        lastRecord = nil
    }

    /// Whether WE draws volumetrics this frame: the setting isn't disabled (WE's trigger,
    /// 0x140196d13) and the content has a plan for it.
    static func runs(_ plan: SceneVolumetricsPlan?, settings: SceneRenderSettings) -> Bool {
        guard let plan else { return false }
        return settings.volumetrics.level > 0 && !plan.lights.isEmpty
    }

    func readsSceneDepth(settings: SceneRenderSettings) -> Bool {
        guard let plan else { return false }
        return Self.runs(plan, settings: settings)
    }

    func encode(_ context: SceneFrameStageContext) {
        lastRecord = nil
        guard let plan, let pipelines, Self.runs(plan, settings: context.settings) else { return }
        let shown = plan.lights.compactMap { planned -> (SceneVolumetricsPlan.Light, simd_float4x4)? in
            guard let object = context.frame.lighting.objects.first(where: { $0.id == planned.id }), object.visible
            else { return nil }
            // The light's fields this frame (scripts, timelines), as WE reads them per light.
            var light = planned
            if let live = object.light { light.light = live }
            return (light, object.world)
        }
        guard !shown.isEmpty, let targets = targets(for: context.scene, quality: plan.quality),
              let back = back(context, targets: targets) else { return }
        let camera = context.frame.camera
        let viewProjection = Self.viewProjection(camera)
        var drawn: [(id: String, fullscreen: Bool)] = []
        for (index, (light, world)) in shown.enumerated() {
            var volume = SceneVolumetricLight(light: light.light, world: world, camera: camera)
            // The light's map transform (+0x310) and a point's projection info (+0x320), as the
            // shadow maps left them (docs/models-plan.md §2.10).
            let shadows = context.frame.lighting.shadows
            volume.renderVars[0] = shadows.lightTransforms[light.id] ?? .zero
            if light.light.kind == .point { volume.renderVars[3] = shadows.pointProjections[light.id] ?? .zero }
            guard encodeLight(light, volume: volume, camera: camera, viewProjection: viewProjection, back: back,
                              targets: targets, clear: index == 0, context: context, pipelines: pipelines) else { return }
            drawn.append((light.id, volume.cameraInside))
        }
        guard finish(plan, lightBuffer: targets.lightBuffer, lightBufferB: targets.lightBufferB, into: context.scene,
                     frame: context.frame, commandBuffer: context.commandBuffer) else { return }
        lastRecord = Record(lights: drawn, quality: plan.quality, lightBuffer: targets.lightBuffer)
    }

    /// The camera's view and projection as the translated shaders get it: the scene target keeps
    /// the scene's top in its first row and the translator flips clip y (`ImageMaterialRenderer`),
    /// so y is mirrored first. `g_EffectModelMatrix` is this one's inverse, so the shaders' world
    /// positions are WE's.
    static func viewProjection(_ camera: SceneFrameCamera) -> simd_float4x4 {
        simd_float4x4(diagonal: SIMD4(1, -1, 1, 1)) * camera.viewProjection
    }

    // MARK: - Per light

    private func encodeLight(_ light: SceneVolumetricsPlan.Light, volume: SceneVolumetricLight, camera: SceneFrameCamera,
                             viewProjection: simd_float4x4, back: MTLTexture, targets: Targets, clear: Bool,
                             context: SceneFrameStageContext, pipelines: SceneVolumetricsPipelines) -> Bool {
        let front = volume.cameraInside ? light.fullscreen : light.front
        let format = targets.lightBuffer.pixelFormat
        guard let mesh = pipelines.mesh(volume.shape),
              let backPipeline = pipelines.pipeline(light.back, color: .invalid, raster: .farFacesDepth),
              let frontPipeline = pipelines.pipeline(front, color: format,
                                                     raster: volume.cameraInside ? .everything : .nearFaces) else { return false }
        let transform = viewProjection * volume.volume
        let winding = SceneVolumetricsPipelines.frontWinding(transform, reversedDepth: camera.reversedDepth)
        var values: [String: [Float]] = [
            "g_ViewProjectionMatrix": SceneVolumetricsPipelines.flat(viewProjection),
            "g_AltViewProjectionMatrix": SceneVolumetricsPipelines.flat(volume.volume),
            "g_AltModelMatrix": SceneVolumetricsPipelines.flat(volume.lightProjection),
            "g_EffectModelMatrix": SceneVolumetricsPipelines.flat(viewProjection.inverse),
            "g_Texture1Resolution": [Float(back.width), Float(back.height), Float(back.width), Float(back.height)],
            "g_Texture3Resolution": [Float(targets.single.width), Float(targets.single.height),
                                     Float(targets.single.width), Float(targets.single.height)],
            "g_EyePosition": [camera.eye.x, camera.eye.y, camera.eye.z],
        ]
        for (index, value) in volume.renderVars.enumerated() {
            values["g_RenderVar\(index)"] = [value.x, value.y, value.z, value.w]
        }
        let size = SIMD2<Float>(Float(targets.lightBuffer.width), Float(targets.lightBuffer.height))

        // The far faces into `_rt_volumetricsSingle`, cleared to the far depth: WE's clear value,
        // 0 (0x14009b130). The translator maps clip depth d to Metal's (d + 1) / 2, so the far
        // plane is 0.5 there, still in front of the clear.
        let backPass = MTLRenderPassDescriptor()
        backPass.depthAttachment.texture = targets.singleDepth
        backPass.depthAttachment.loadAction = .clear
        backPass.depthAttachment.clearDepth = 0
        backPass.depthAttachment.storeAction = .store
        guard let backEncoder = context.commandBuffer.makeRenderCommandEncoder(descriptor: backPass) else { return false }
        backEncoder.label = "volumetrics back \(light.id)"
        backEncoder.setRenderPipelineState(backPipeline)
        backEncoder.setDepthStencilState(pipelines.farDepth)
        backEncoder.setFrontFacing(winding)
        backEncoder.setCullMode(.front)
        bind(SceneVolumetricsPipelines.uniforms(light.back, values: values, frame: context.frame, targetSize: size),
             to: backEncoder)
        backEncoder.setVertexBuffer(mesh.positions, offset: 0, index: EffectGraphRenderer.positionBuffer)
        backEncoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint16,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0)
        backEncoder.endEncoding()
        pipelines.encodeClipDepth(targets.singleDepth, into: targets.single, commandBuffer: context.commandBuffer)

        // The ray march into `_rt_volumetricsLightBuffer`, additive.
        let frontPass = MTLRenderPassDescriptor()
        frontPass.colorAttachments[0].texture = targets.lightBuffer
        frontPass.colorAttachments[0].loadAction = clear ? .clear : .load
        frontPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        frontPass.colorAttachments[0].storeAction = .store
        guard let encoder = context.commandBuffer.makeRenderCommandEncoder(descriptor: frontPass) else { return false }
        encoder.label = "volumetrics front \(light.id)"
        encoder.setRenderPipelineState(frontPipeline)
        encoder.setDepthStencilState(pipelines.noDepth)
        bind(SceneVolumetricsPipelines.uniforms(front, values: values, frame: context.frame, targetSize: size), to: encoder)
        for (slot, texture) in [(1, back), (3, targets.single)] {
            encoder.setFragmentTexture(texture, index: slot)
            encoder.setFragmentSamplerState(pipelines.nearestClamp, index: slot)
        }
        // A shadow-casting light reads its map (`SHADOW`, `_rt_shadowAtlas` as `g_Texture0`).
        if SceneVolumetricsPlan.castsShadow(light.light, shadowQuality: context.settings.shadows.level) {
            guard let atlas = context.shadowAtlas, let shadowSampler else {
                encoder.endEncoding()
                return false
            }
            encoder.setFragmentTexture(atlas, index: 0)
            encoder.setFragmentSamplerState(shadowSampler, index: 0)
        }
        if let cookie = light.cookie, let texture = context.assetTexture?(cookie.key, cookie.source) {
            encoder.setFragmentTexture(texture, index: 2)
            encoder.setFragmentSamplerState(pipelines.linearClamp, index: 2)
        }
        if volume.cameraInside {
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(pipelines.fullscreenTriangle, offset: 0, index: EffectGraphRenderer.positionBuffer)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        } else {
            encoder.setFrontFacing(winding)
            encoder.setCullMode(.back)
            encoder.setVertexBuffer(mesh.positions, offset: 0, index: EffectGraphRenderer.positionBuffer)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint16,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0)
        }
        encoder.endEncoding()
        return true
    }

    // MARK: - Finishing

    /// WE's finish (0x140198d00): below quality 3 the light buffer is blurred across and then
    /// down through `lightBufferB`, and `volumetrics_combine` adds it to `scene`. False while a
    /// pipeline isn't ready.
    @discardableResult
    func finish(_ plan: SceneVolumetricsPlan, lightBuffer: MTLTexture, lightBufferB: MTLTexture?, into scene: MTLTexture,
                frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let pipelines else { return false }
        if let blurH = plan.blurH, let blurV = plan.blurV, let lightBufferB {
            guard quad(blurH, from: lightBuffer, into: lightBufferB, load: false, frame: frame,
                       commandBuffer: commandBuffer, pipelines: pipelines),
                  quad(blurV, from: lightBufferB, into: lightBuffer, load: false, frame: frame,
                       commandBuffer: commandBuffer, pipelines: pipelines) else { return false }
        }
        return quad(plan.combine, from: lightBuffer, into: scene, load: true, frame: frame,
                    commandBuffer: commandBuffer, pipelines: pipelines)
    }

    /// One full-target pass of `pass` reading `source` as `g_Texture0`.
    private func quad(_ pass: SceneVolumetricsPass, from source: MTLTexture, into target: MTLTexture, load: Bool,
                      frame: BuiltinFrameContext, commandBuffer: MTLCommandBuffer,
                      pipelines: SceneVolumetricsPipelines) -> Bool {
        guard let pipeline = pipelines.pipeline(pass, color: target.pixelFormat, raster: .everything) else { return false }
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = load ? .load : .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        encoder.label = (pass.material as NSString).lastPathComponent
        encoder.setRenderPipelineState(pipeline)
        let size = SIMD2<Float>(Float(source.width), Float(source.height))
        let values = ["g_Texture0Resolution": [size.x, size.y, size.x, size.y]]
        bind(SceneVolumetricsPipelines.uniforms(pass, values: values, frame: frame,
                                                targetSize: SIMD2(Float(target.width), Float(target.height))), to: encoder)
        encoder.setVertexBuffer(pipelines.quadPositions, offset: 0, index: EffectGraphRenderer.positionBuffer)
        encoder.setVertexBuffer(pipelines.quadTexCoords, offset: 0, index: EffectGraphRenderer.texCoordBuffer)
        encoder.setVertexBuffer(pipelines.zeroAttributes, offset: 0, index: EffectGraphRenderer.zeroBuffer)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(pipelines.linearClamp, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        return true
    }

    private func bind(_ bytes: [UInt8], to encoder: MTLRenderCommandEncoder) {
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 0)
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
        }
    }

    // MARK: - Targets

    /// WE's targets for a scene of `scene`'s size (0x140196d63…0x140196f31): the light buffers and
    /// `_rt_volumetricsSingle` at 1/4 from quality 3, else 1/8, and the second light buffer only
    /// where it blurs. Made again when the size, format or quality changes.
    private func targets(for scene: MTLTexture, quality: Int) -> Targets? {
        let size = SIMD2(scene.width, scene.height)
        let divisor = SceneVolumetricsPlan.divisor(quality: quality)
        let format = SceneVolumetricsPipelines.lightBufferFormat(scene: scene.pixelFormat)
        if let targets, targets.sceneSize == size, targets.divisor == divisor, targets.format == format,
           (targets.lightBufferB != nil) == SceneVolumetricsPlan.blurs(quality: quality) {
            return targets
        }
        let width = max(1, scene.width / divisor), height = max(1, scene.height / divisor)
        func make(_ pixelFormat: MTLPixelFormat, _ usage: MTLTextureUsage, _ label: String) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width,
                                                                      height: height, mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = .private
            let texture = device.makeTexture(descriptor: descriptor)
            texture?.label = label
            return texture
        }
        let blurs = SceneVolumetricsPlan.blurs(quality: quality)
        guard let lightBuffer = make(format, [.renderTarget, .shaderRead], "_rt_volumetricsLightBuffer"),
              let singleDepth = make(.depth32Float, [.renderTarget, .shaderRead], "_rt_volumetricsSingle depth"),
              let single = make(.r32Float, [.shaderRead, .shaderWrite], "_rt_volumetricsSingle") else {
            report("Could not allocate the \(width)×\(height) volumetrics targets")
            return nil
        }
        var lightBufferB: MTLTexture?
        if blurs {
            guard let made = make(format, [.renderTarget, .shaderRead], "_rt_volumetricsLightBufferB") else {
                report("Could not allocate the \(width)×\(height) volumetrics blur target")
                return nil
            }
            lightBufferB = made
        }
        let made = Targets(sceneSize: size, divisor: divisor, format: format, lightBuffer: lightBuffer,
                           lightBufferB: lightBufferB, singleDepth: singleDepth, single: single)
        targets = made
        return made
    }

    /// `_rt_volumetricsBack` this frame: the scene's depth as clip depth, or the far depth
    /// without one.
    private func back(_ context: SceneFrameStageContext, targets: Targets) -> MTLTexture? {
        guard let depth = context.sceneDepth else { return farDepthTexel() }
        if let back = targets.back, back.width == depth.width, back.height == depth.height {
            pipelines?.encodeClipDepth(depth, into: back, commandBuffer: context.commandBuffer)
            return back
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: depth.width,
                                                                  height: depth.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let back = device.makeTexture(descriptor: descriptor) else {
            report("Could not allocate the \(depth.width)×\(depth.height) _rt_volumetricsBack")
            return nil
        }
        back.label = "_rt_volumetricsBack"
        self.targets?.back = back
        pipelines?.encodeClipDepth(depth, into: back, commandBuffer: context.commandBuffer)
        return back
    }

    private func farDepthTexel() -> MTLTexture? {
        if let farBack { return farBack }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var far = SceneVolumeMesh.farDepth
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &far, bytesPerRow: 4)
        texture.label = "_rt_volumetricsBack (far)"
        farBack = texture
        return texture
    }

    private func report(_ message: String) {
        guard !reportedFailure else { return }
        reportedFailure = true
        OWELog.error(.scene, message)
    }
}
