import Metal

/// WE's `_rt_MipMappedFrameBuffer`: a copy of the finished scene with mipmaps, which materials
/// sample for screen-space reflection (`genericimage4`'s `REFLECTION` with `NORMALMAP` reads it at
/// mip `roughness · g_Texture3MipMapInfo`; docs/lighting-plan.md §2.4).
///
/// From `wallpaper64.exe`:
/// - **Creation** (0x140181c8b…0x140181dc5): only while an object of the scene reports that it
///   samples it. Full render size (divisor 1), the frame-buffer format (RGBA8 in LDR, RGBA16F in
///   HDR), created with the mipmap flag 0x10. Here: while the content samples it (`samples(_:)`),
///   at the scene target's size and format, which is WE's frame-buffer class.
/// - **Mip count** (the render-target constructor, 0x1400d2dde…0x1400d2e76): `mipCount(width:height:)`.
///   `g_TextureNMipMapInfo` is that count as a float (uniform setter 0x1400d98f4 reads the
///   texture's level count, 1 without a texture), which `EffectGraphRenderer.textureInfo` gives
///   from the texture's `mipmapLevelCount`.
/// - **Filling** (0x140180a8c…0x140180aad): after the main pass, while render flag 0x80 (the
///   user's reflection setting) is set, the frame is copied in (the target's vt+0x8, a
///   `CopyResource` of the bound target) and its mips generated (vt+0x20, `GenerateMips`). So a
///   material drawn in the main pass reads the **previous** frame. With the setting off it is
///   cleared once to (0, 0, 0, 1) (0x140181d2b…0x140181d61) and never filled.
///
/// It runs as the first `SceneFrameStage`. The renderer asks for `target(matching:commandBuffer:)`
/// before the scene pass, and binds it wherever a material, effect or particle pass samples
/// `_rt_MipMappedFrameBuffer` (`SceneEffectTextureInput.mipMappedFrameBuffer`).
final class SceneMipMappedFrameBuffer: SceneFrameStage {
    /// The texture name materials use for it.
    static let name = "_rt_MipMappedFrameBuffer"

    private enum Contents {
        /// Transparent black, as a new D3D target reads.
        case empty
        /// (0, 0, 0, 1): the reflection setting is off.
        case black
        /// A frame and its mips.
        case frame
    }

    private let device: MTLDevice
    /// The content samples the target, so it exists (WE's creation condition).
    private(set) var isSampled = false
    /// The target, once made for a frame; nil while nothing samples it.
    private(set) var texture: MTLTexture?
    private var contents = Contents.empty
    /// Frames copied in since creation, for tests and diagnostics.
    private(set) var framesCopied = 0
    /// A failed allocation is logged once.
    private var reportedAllocationFailure = false

    init(device: MTLDevice) {
        self.device = device
    }

    /// WE's mip count for a `width`×`height` target: for each side, log2 of half the smallest power
    /// of two not below it (1920 and 2048 → 10, 1080 → 10); the smaller of the two, minus 2, and at
    /// least 1. 1920×1080 has 8 levels, down to 15×8.
    static func mipCount(width: Int, height: Int) -> Int {
        func log2OfHalfCeilingPowerOfTwo(_ side: Int) -> Int {
            // WE stores the size in 16 bits, at least 2 (0x1400d2c96…0x1400d2ce4).
            let size = max(2, min(side, Int(UInt16.max)))
            var ceiling = 1
            while ceiling < size { ceiling <<= 1 }
            return (ceiling >> 1).trailingZeroBitCount
        }
        let levels = min(log2OfHalfCeilingPowerOfTwo(width), log2OfHalfCeilingPowerOfTwo(height)) - 2
        return max(1, levels)
    }

    /// Whether any material, effect or particle pass of `content` samples the target.
    static func samples(_ content: SceneMetalContent) -> Bool {
        func samples(_ textures: [Int: SceneEffectTextureInput]) -> Bool {
            textures.values.contains { if case .mipMappedFrameBuffer = $0 { return true } else { return false } }
        }
        return content.layers.contains { layer in
            (layer.imageMaterial.map { samples($0.pass.textures) || samples($0.prelighting?.textures ?? [:]) } ?? false)
                || layer.weEffects.contains { $0.passes.contains { samples($0.textures) } }
        } || content.particleSystems.contains { system in
            ([system.material] + system.additionalRenderers.map(\.material)).contains { material in
                material?.stages.contains { samples($0.textures) } ?? false
            }
        } || content.spatial.models.contains { model in
            model.plan?.meshes.contains { $0.material.passes.contains { samples($0.pass.textures) } } ?? false
        }
    }

    /// WE makes the target with the scene it loads, so a new content never reads the last one's
    /// frame: the target is made again, transparent black, on the next frame.
    /// Whether `layer` samples the target in the scene pass: through its own material, or, for a
    /// layer that reads the scene (its effects run inside the pass), through its prepass or effects.
    /// Any other layer's effects run before the scene pass.
    static func readsInScenePass(_ layer: SceneMetalLayer) -> Bool {
        func samples(_ textures: [Int: SceneEffectTextureInput]) -> Bool {
            textures.values.contains { if case .mipMappedFrameBuffer = $0 { return true } else { return false } }
        }
        if let material = layer.imageMaterial, samples(material.pass.textures) { return true }
        guard layer.readsScene else { return false }
        return samples(layer.imageMaterial?.prelighting?.textures ?? [:])
            || layer.weEffects.contains { $0.passes.contains(where: \.readsMipMappedFrameBuffer) }
    }

    /// Whether this frame's scene snapshot (the scene so far, for layers that read it) can be taken
    /// into the target's level 0 instead of a full-size target of its own (test-risks LR10). It can
    /// when the reflection copy runs this frame, which overwrites level 0 and makes the mips again
    /// once the scene is drawn (with the setting off the target must stay black), when no particle
    /// system samples the target, and when nothing from the first layer that reads the scene on
    /// samples it in the scene pass: the draws before that read the previous frame before the
    /// snapshot overwrites it, as the command buffer orders them. `layers` are in draw order.
    static func snapshotCanShare<Layers: Sequence>(layers: Layers, particleSystems: [SceneMetalParticleSystem],
                                                   reflection: Bool) -> Bool where Layers.Element == SceneMetalLayer {
        guard reflection else { return false }
        let particlesSample = particleSystems.contains { system in
            system.material?.stages.contains { $0.textures.values.contains {
                if case .mipMappedFrameBuffer = $0 { return true } else { return false }
            } } ?? false
        }
        guard !particlesSample else { return false }
        var readingScene = false
        for layer in layers {
            if layer.readsScene { readingScene = true }
            if readingScene, readsInScenePass(layer) { return false }
        }
        return true
    }

    func setContent(_ content: SceneMetalContent) {
        isSampled = Self.samples(content)
        texture = nil
        contents = .empty
    }

    /// The target this frame's draws sample, (re)made to match `scene` (the scene target); nil
    /// while nothing samples it or when it can't be allocated. A new target reads as transparent
    /// black until the end of its first frame.
    func target(matching scene: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard isSampled else { return nil }
        if let texture, texture.width == scene.width, texture.height == scene.height,
           texture.pixelFormat == scene.pixelFormat {
            return texture
        }
        let levels = Self.mipCount(width: scene.width, height: scene.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: scene.pixelFormat, width: scene.width,
                                                                  height: scene.height, mipmapped: true)
        descriptor.mipmapLevelCount = levels
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let made = device.makeTexture(descriptor: descriptor) else {
            if !reportedAllocationFailure {
                reportedAllocationFailure = true
                OWELog.error(.scene, "Could not allocate the \(scene.width)×\(scene.height) \(Self.name) (\(levels) mips)")
            }
            texture = nil
            return nil
        }
        made.label = Self.name
        texture = made
        clear(made, to: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0), commandBuffer: commandBuffer)
        contents = .empty
        return made
    }

    func encode(_ context: SceneFrameStageContext) {
        guard let texture = target(matching: context.scene, commandBuffer: context.commandBuffer) else { return }
        guard context.settings.reflection else {
            if contents != .black {
                clear(texture, to: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1), commandBuffer: context.commandBuffer)
                contents = .black
            }
            return
        }
        guard let blit = context.commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = Self.name
        blit.copy(from: context.scene, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        if texture.mipmapLevelCount > 1 { blit.generateMipmaps(for: texture) }
        blit.endEncoding()
        contents = .frame
        framesCopied += 1
    }

    /// Clears every level, since a material may sample any of them.
    private func clear(_ texture: MTLTexture, to color: MTLClearColor, commandBuffer: MTLCommandBuffer) {
        for level in 0..<texture.mipmapLevelCount {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].level = level
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = color
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.label = "\(Self.name) clear"
            encoder.endEncoding()
        }
    }
}
