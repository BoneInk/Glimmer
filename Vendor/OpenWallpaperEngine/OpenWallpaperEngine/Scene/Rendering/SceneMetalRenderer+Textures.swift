import Cocoa
import MetalKit
import CryptoKit
import OWESceneEditing

extension SceneMetalRenderer {
    /// The user's colour for a text layer (`_owe_text_<id>_color`), white when unset.
    func textTint(layerID: String) -> SIMD3<Float> {
        guard let value = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_color") else {
            return SIMD3(repeating: 1)
        }
        let rgb = value.parseVector3()
        return SIMD3(Float(rgb.0), Float(rgb.1), Float(rgb.2))
    }

    /// `layerID` keys the user's text settings and the text cache. `pointSize` is a script's
    /// `pointsize`, which wins over the app's size setting. `fill` nil rasterises white coverage,
    /// coloured when drawn; a colour rasterises the text in it, as WE's `font` pass draws it into
    /// the buffer its effects run on and other layers sample (3378346807's cyan clock).
    func makeTextFrame(_ text: SceneMetalText, value: String, pointSize: Float?, boxSize: SIMD2<Float>,
                       pixelsPerUnit: Float, layerID: String,
                       fill: SIMD3<Float>?) -> (frame: RenderTextureFrame, baseSize: SIMD2<Float>)? {
        let stateKey = layerID
        let fontName = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_font") ?? ""
        let sizeValue = pointSize
            ?? WallpaperServices.shared.userPropertyValue("_owe_text_\(layerID)_size", fallback: Float(text.pointSize))
        let bold = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_bold") == "true"
        let italic = WallpaperServices.shared.userPropertyString("_owe_text_\(layerID)_italic") == "true"
        let rasterScale = textRasterScales[stateKey, default: SceneTextRasterScale.Tracker()].scale(for: pixelsPerUnit)
        let cacheKey = "\(stateKey)|\(value)|\(boxSize.x)|\(boxSize.y)|\(fontName)|\(sizeValue)|\(bold)|\(italic)|\(rasterScale)"
            + "|\(text.layoutKey)"
            + (fill.map { "|\($0)" } ?? "")
        let slot = "\(stateKey)|\(fill != nil)|\(pixelsPerUnit == 1)"
        for done in textRaster.takeFinished() {
            if let result = done.result { textFrameCache.insert(result, for: done.key, cost: result.cost) }
        }
        if let cached = textFrameCache.value(for: cacheKey) {
            textRaster.show(cached, slot: slot)
            return (cached.frame, cached.baseSize)
        }
        // A changed string is rasterised on a pool job while the previous raster keeps drawing.
        let request = SceneTextRasterRequest(text: text, value: value,
                                             fontName: fontName.isEmpty ? (text.font ?? "") : fontName,
                                             pointSize: sizeValue, bold: bold, italic: italic,
                                             rasterScale: rasterScale, fill: fill)
        guard let (result, isNew) = textRaster.raster(key: cacheKey, slot: slot, request: request) else {
            OWELog.error(.scene, "Text layer \(layerID): could not rasterise")
            return nil
        }
        if isNew { textFrameCache.insert(result, for: cacheKey, cost: result.cost) }
        return (result.frame, result.baseSize)
    }

    func clearUploadedImages() {
        uploadedImagesLock.lock()
        uploadedImages.removeAllObjects()
        particleMipmaps.removeAll()
        uploadedImagesLock.unlock()
    }

    /// A particle system's texture 0 with its mip chain; systems that share a texture share it.
    /// A sprite sheet keeps the levels its file stores: a generated chain would bleed its cells
    /// into each other at the small levels.
    func particleTexture(from source: SceneMetalTextureSource, spriteSheet: Bool) -> MTLTexture? {
        guard let texture = makeTextureFrames(from: source)?.first?.texture else { return nil }
        guard !spriteSheet, ParticleTextureMipmaps.needsChain(texture) else { return texture }
        let key = ObjectIdentifier(texture)
        uploadedImagesLock.lock()
        let cached = particleMipmaps[key]?.chained
        uploadedImagesLock.unlock()
        if let cached { return cached }
        let chained = ParticleTextureMipmaps.mipmapped(texture, device: device, queue: commandQueue)
        uploadedImagesLock.lock()
        defer { uploadedImagesLock.unlock() }
        if let raced = particleMipmaps[key]?.chained { return raced }
        particleMipmaps[key] = (texture, chained)
        return chained
    }

    func makeTextureFrames(from source: SceneMetalTextureSource) -> [RenderTextureFrame]? {
        guard case let .image(image) = source else { return uploadTextureFrames(from: source) }
        uploadedImagesLock.lock()
        let cached = uploadedImages.object(forKey: image)?.frames
        uploadedImagesLock.unlock()
        if let cached { return cached }
        guard let frames = uploadTextureFrames(from: source) else { return nil }
        uploadedImagesLock.lock()
        defer { uploadedImagesLock.unlock() }
        if let raced = uploadedImages.object(forKey: image)?.frames { return raced }
        uploadedImages.setObject(UploadedFrames(frames), forKey: image)
        return frames
    }

    private func uploadTextureFrames(from source: SceneMetalTextureSource) -> [RenderTextureFrame]? {
        switch source {
        case let .image(image):
            if let raw = TEXRawImageRep.of(image) {
                // Its allocation, padding and all, as a block-compressed .tex (`contentUVExtent`).
                guard let texture = raw.makeAllocationTexture(device: device) else {
                    OWELog.error(.scene, "Could not upload a \(raw.pixelsWide)×\(raw.pixelsHigh) .tex image")
                    return nil
                }
                let crop = raw.isPadded ? raw.contentUVExtent : SIMD2<Float>(1, 1)
                return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                           uvOrigin: .zero, uvAxisX: SIMD2<Float>(crop.x, 0), uvAxisY: SIMD2<Float>(0, crop.y))]
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let texture: MTLTexture
            do {
                texture = try SceneTextureUpload.texture(from: cgImage, loader: textureLoader, device: device)
            } catch {
                OWELog.error(.scene, "Could not upload a \(cgImage.width)×\(cgImage.height) image: \(error)")
                return nil
            }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .dxt(source):
            guard let texture = makeDXTTexture(source) else { return nil }
            let crop = Self.contentUVExtent(source)
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(crop.x, 0), uvAxisY: SIMD2<Float>(0, crop.y))]
        case let .video(stream):
            // Stand-in until the first frame decodes; draw() swaps in the live texture.
            guard let texture = stream.currentTexture() ?? makePlaceholderTexture() else { return nil }
            return [RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                       uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))]
        case let .animated(animation):
            let textures = animation.images.compactMap { image -> MTLTexture? in
                if let raw = TEXRawImageRep.of(image) { return raw.makeTexture(device: device) }
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                do {
                    return try SceneTextureUpload.texture(from: cgImage, loader: textureLoader, device: device)
                } catch {
                    OWELog.error(.scene, "Could not upload a \(cgImage.width)×\(cgImage.height) animation frame: \(error)")
                    return nil
                }
            }
            guard textures.count == animation.images.count else { return nil }
            return animation.frames.compactMap { frame in
                guard frame.imageIndex < textures.count else { return nil }
                // Frame rects are in the atlas's pixels; the texture was made from those pixels,
                // whatever size in points the image reports. WidthY/HeightX shear or turn the rect.
                let atlas = textures[frame.imageIndex]
                let atlasSize = SIMD2<Float>(Float(atlas.width), Float(atlas.height))
                guard atlasSize.x > 0, atlasSize.y > 0 else { return nil }
                return RenderTextureFrame(texture: textures[frame.imageIndex], duration: frame.duration,
                                          uvOrigin: SIMD2<Float>(frame.x, frame.y) / atlasSize,
                                          uvAxisX: SIMD2<Float>(frame.width, frame.widthY) / atlasSize,
                                          uvAxisY: SIMD2<Float>(frame.heightX, frame.height) / atlasSize)
            }
        case .uploaded:
            // Its pixels were dropped after its first upload; a new upload loads the file again.
            OWELog.error(.scene, "An uploaded image was handed back for upload without its pixels")
            return nil
        }
    }

    /// The part of a padded .tex allocation the image covers, in UV units: the quad samples only
    /// the image, never the padding around it.
    static func contentUVExtent(_ texture: TEXCompressedTexture) -> SIMD2<Float> {
        guard texture.width > 0, texture.height > 0, texture.contentWidth > 0, texture.contentHeight > 0 else {
            return SIMD2(1, 1)
        }
        return simd_min(SIMD2(Float(texture.contentWidth) / Float(texture.width),
                              Float(texture.contentHeight) / Float(texture.height)), SIMD2(1, 1))
    }

    private func makePlaceholderTexture() -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        var pixel: UInt32 = 0
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        return texture
    }

    /// The layer's texture this frame: a video's current picture, or the sprite frame of an
    /// animated texture from the instance's texture clocks (docs/timeline-plan.md §2.7, §3.2),
    /// taken once per frame (a script's override advances each time it is asked).
    func textureFrame(for entry: PreparedLayer) -> RenderTextureFrame {
        let frame = currentTextureFrame(for: entry)
        // What a `layerimage` emitter sampling the layer again reads.
        emitterImages.record(frame, layer: entry.layer.id)
        return frame
    }

    private func currentTextureFrame(for entry: PreparedLayer) -> RenderTextureFrame {
        // A puppet's image is its mesh's drawing, laid out like its source texture.
        if entry.layer.puppet != nil, let albedo = puppetAlbedos[entry.layer.id] {
            let source = entry.frames[0]
            return RenderTextureFrame(texture: albedo, duration: source.duration, uvOrigin: source.uvOrigin,
                                      uvAxisX: source.uvAxisX, uvAxisY: source.uvAxisY)
        }
        // A video layer's texture is replaced every frame, so the decoded frame list is only a seed.
        if case let .video(stream) = entry.layer.source, let texture = stream.currentTexture() {
            return RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                      uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))
        }
        // A system texture (the now-playing artwork) replaces the image while there is one.
        if let kind = entry.layer.systemImage, let texture = systemTexture(kind) {
            return RenderTextureFrame(texture: texture, duration: .greatestFiniteMagnitude,
                                      uvOrigin: .zero, uvAxisX: SIMD2<Float>(1, 0), uvAxisY: SIMD2<Float>(0, 1))
        }
        guard entry.frames.count > 1, let id = Int(entry.layer.id) else { return entry.frames[0] }
        let frame = timelines.spriteFrame(object: id, delta: Float(clock.delta))
        drawProbe?.record(spriteFrame: frame, object: id)
        // `setFrame(n)` isn't range-checked; a frame outside the sheet draws the first.
        return frame >= 0 && Int(frame) < entry.frames.count ? entry.frames[Int(frame)] : entry.frames[0]
    }

    /// A system texture's image now; nil without one (or without script services).
    func systemTexture(_ kind: SceneSystemTexture) -> MTLTexture? {
        mediaTextures?.texture(kind)
    }

    private func makeDXTTexture(_ source: TEXCompressedTexture) -> MTLTexture? {
        // DXT1/3/5 are BC1/BC2/BC3. Apple Silicon Macs consume those natively, so upload the
        // blocks as-is, with every stored mipmap, instead of expanding them to rgba8Unorm through
        // the decode kernel.
        if SceneTextureUpload.blockFormat(for: source.format) != nil, device.supportsBCTextureCompression {
            return SceneTextureUpload.blockCompressedTexture(source, device: device)
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                    width: source.width, height: source.height,
                                                                    mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let input = device.makeBuffer(bytes: source.data, length: source.data.count, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var uniform = DXTDecodeUniform(width: UInt32(source.width), height: UInt32(source.height),
                                       blockColumns: UInt32((source.width + 3) / 4), format: source.format)
        encoder.setComputePipelineState(dxtDecodePipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&uniform, length: MemoryLayout<DXTDecodeUniform>.stride, index: 1)
        let threads = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreads(MTLSize(width: source.width, height: source.height, depth: 1), threadsPerThreadgroup: threads)
        encoder.endEncoding()
        commandBuffer.commit()
        // Keep the decode asynchronous. Metal command buffers on the same queue
        // preserve ordering, so later scene draws wait on this texture on-GPU
        // without blocking the render/content thread here.
        return texture
    }
}
