import Metal

/// A particle texture with its full mip chain, as WE samples particles (its `.tex` files carry
/// mipmaps and the particle sampler filters between them). Block-compressed `.tex` uploads keep
/// the levels the file stores; an image uploaded with one level (PNG, JPEG, raw RGBA `.tex`) gets
/// its chain generated on the GPU, so a particle drawn smaller than its texture doesn't shimmer
/// and reads a fraction of the texels.
enum ParticleTextureMipmaps {
    /// Levels of a full chain for a `width` × `height` texture.
    static func levelCount(width: Int, height: Int) -> Int {
        var size = max(width, height, 1), levels = 1
        while size > 1 { size >>= 1; levels += 1 }
        return levels
    }

    /// Whether `texture` needs a generated chain: one level, larger than a texel, in a format the
    /// GPU can filter and render into (generating mipmaps needs both).
    static func needsChain(_ texture: MTLTexture) -> Bool {
        guard texture.textureType == .type2D, texture.mipmapLevelCount == 1,
              max(texture.width, texture.height) > 1 else { return false }
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb, .bgra8Unorm, .bgra8Unorm_srgb, .r8Unorm, .rg8Unorm,
             .rgba16Float, .r16Float, .rg16Float:
            return true
        default:
            return false
        }
    }

    /// `texture` with a generated mip chain, encoded on `queue` and committed without waiting (the
    /// frames that sample it run later on the same queue); `texture` itself when it needs none or
    /// the copy can't be made.
    static func mipmapped(_ texture: MTLTexture, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture {
        guard needsChain(texture) else { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: true)
        descriptor.mipmapLevelCount = levelCount(width: texture.width, height: texture.height)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        guard let chained = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            OWELog.error(.scene, "Could not make a \(texture.width)×\(texture.height) particle texture's mip chain")
            return texture
        }
        commandBuffer.label = "Particle texture mipmaps"
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: chained, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: chained)
        blit.endEncoding()
        commandBuffer.commit()
        return chained
    }
}
