import Metal
import simd

/// Effects drawn with no more detail than the display shows (`GSSceneDetail.matchDisplay`).
///
/// WE draws a layer's effects at its image's size, however small the layer is on screen: a
/// 2760 × 4466 image shown 1100 pixels tall shades every pass at 12 megapixels. Here the chain runs
/// on a copy of the image scaled down to the layer's on-screen size (`footprint`), each texel the
/// average of the image area it covers, and its built-ins report the image's size
/// (`EffectGraphRenderer.Context.inputStandInSize`), so texel-sized steps (blur kernels, shake
/// amplitudes in texels) span the same part of the image. The result is the full-size chain's
/// output as the display would show it, never below the display's resolution: the copy is never
/// smaller than the footprint, and never larger than the image.
///
/// The footprint moves with scripts, timelines and parallax, so the scale is re-evaluated every
/// frame: a layer that grows gets a bigger copy that same frame; one that shrinks keeps its copy
/// until it has been at least `shrinkRatio` smaller for `shrinkFrames` frames, so an animated
/// scale doesn't reallocate the chain every frame.
final class SceneEffectDetail {
    /// Scales are quantised up to sixteenths of the image.
    static let step: Float = 1 / 16
    /// A copy this close to the image's size uses the image itself.
    static let wholeImageScale: Float = 15 / 16
    /// A layer shrinks its copy once it needs at most this fraction of it…
    static let shrinkRatio: Float = 0.8
    /// …for this many frames in a row.
    static let shrinkFrames = 45
    /// Taps per axis of the downsample, at most (a 16× reduction averages 256 taps per texel).
    static let maximumTaps = 16

    /// A layer's scale and its hysteresis.
    struct Scale: Equatable {
        private(set) var value: Float = 1
        private var framesBelow = 0

        /// The scale `needed` (the footprint over the image, per axis at most) asks for, after the
        /// hysteresis: grows at once, shrinks after `shrinkFrames` frames below `shrinkRatio`.
        mutating func update(needed: Float) -> Float {
            let wanted = SceneEffectDetail.quantized(needed)
            if wanted >= value {
                value = wanted
                framesBelow = 0
            } else if wanted <= value * SceneEffectDetail.shrinkRatio {
                framesBelow += 1
                if framesBelow >= SceneEffectDetail.shrinkFrames {
                    value = wanted
                    framesBelow = 0
                }
            } else {
                framesBelow = 0
            }
            return value
        }
    }

    /// `EffectDetailDownsample` in SceneEffectDetail.metal.
    private struct DownsampleParameters {
        var ratio: SIMD2<Float>
        var taps: SIMD2<UInt32>
    }

    private struct Copy {
        let source: MTLTexture
        let version: UInt64
        let texture: MTLTexture
    }

    private let device: MTLDevice
    private let pipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private let sampler: MTLSamplerState
    private var scales: [String: Scale] = [:]
    private var copies: [String: Copy] = [:]
    /// Copies made, for tests and diagnostics.
    private(set) var copiesMade = 0

    init?(device: MTLDevice) {
        guard let library = SceneMetalLibrary.make(device: device),
              let vertex = library.makeFunction(name: "effectDetailVertex"),
              let fragment = library.makeFunction(name: "effectDetailDownsample") else { return nil }
        var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
        for format in [MTLPixelFormat.rgba8Unorm, .rgba16Float] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = format
            do {
                pipelines[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                OWELog.error(.scene, "Effect detail downsample pipeline (\(format.rawValue)) failed: \(error)")
                return nil
            }
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.device = device
        self.pipelines = pipelines
        self.sampler = sampler
    }

    /// Scale `needed` is `footprint` (the whole image's on-screen size in pixels) over `imageSize`,
    /// the larger of the two axes (one scale keeps the aspect), at most 1.
    static func neededScale(footprint: SIMD2<Float>, imageSize: SIMD2<Int>) -> Float {
        guard imageSize.x > 0, imageSize.y > 0, footprint.x.isFinite, footprint.y.isFinite else { return 1 }
        let ratio = footprint / SIMD2(Float(imageSize.x), Float(imageSize.y))
        return min(1, max(ratio.x, ratio.y, 0))
    }

    /// `needed` rounded up to a sixteenth, the whole image once it is nearly all of it.
    static func quantized(_ needed: Float) -> Float {
        guard needed.isFinite, needed < wholeImageScale else { return 1 }
        return max(step, (needed / step).rounded(.up) * step)
    }

    /// The copy's size for an image of `imageSize` at `scale`: rounded up, at least 1.
    static func copySize(_ imageSize: SIMD2<Int>, scale: Float) -> SIMD2<Int> {
        guard scale < 1 else { return imageSize }
        return SIMD2(Int(saturating: (Float(imageSize.x) * scale).rounded(.up), in: 1...Int.max),
                     Int(saturating: (Float(imageSize.y) * scale).rounded(.up), in: 1...Int.max))
    }

    /// The image layer `layerID`'s effects run on this frame, for `image` shown `footprint` pixels
    /// large: `image` itself (stand-in nil) or its smaller copy, with the size it stands for. The
    /// copy is remade when the image, its `version` (bumped when its contents change in place) or
    /// the scale changes.
    func input(for image: MTLTexture, version: UInt64, layerID: String, footprint: SIMD2<Float>,
               commandBuffer: MTLCommandBuffer) -> (texture: MTLTexture, standIn: SIMD2<Int>?) {
        let imageSize = SIMD2(image.width, image.height)
        var layerScale = scales[layerID] ?? Scale()
        let scale = layerScale.update(needed: Self.neededScale(footprint: footprint, imageSize: imageSize))
        scales[layerID] = layerScale
        let size = Self.copySize(imageSize, scale: scale)
        guard size != imageSize else {
            copies[layerID] = nil
            return (image, nil)
        }
        if let copy = copies[layerID], copy.source === image, copy.version == version,
           copy.texture.width == size.x, copy.texture.height == size.y {
            return (copy.texture, imageSize)
        }
        guard let texture = makeCopy(of: image, size: size, commandBuffer: commandBuffer) else { return (image, nil) }
        copies[layerID] = Copy(source: image, version: version, texture: texture)
        return (texture, imageSize)
    }

    /// Forgets a layer (removed, or its content replaced).
    func releaseLayer(_ layerID: String) {
        scales[layerID] = nil
        copies[layerID] = nil
    }

    func releaseAll() {
        scales.removeAll()
        copies.removeAll()
    }

    private func makeCopy(of image: MTLTexture, size: SIMD2<Int>, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let format: MTLPixelFormat = Self.isFloat(image.pixelFormat) ? .rgba16Float : .rgba8Unorm
        guard let pipeline = pipelines[format] else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.x, height: size.y,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Could not allocate a \(size.x)×\(size.y) effect input")
            return nil
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let ratio = simd_max(SIMD2(Float(image.width) / Float(size.x), Float(image.height) / Float(size.y)), SIMD2(1, 1))
        let taps = SIMD2<UInt32>(min(UInt32(ratio.x.rounded(.up)), UInt32(Self.maximumTaps)),
                                 min(UInt32(ratio.y.rounded(.up)), UInt32(Self.maximumTaps)))
        var params = DownsampleParameters(ratio: ratio, taps: taps)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<DownsampleParameters>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        copiesMade += 1
        return texture
    }

    private static func isFloat(_ format: MTLPixelFormat) -> Bool {
        [.rgba16Float, .rgba32Float, .rg16Float, .r16Float, .rg11b10Float, .rgb9e5Float].contains(format)
    }
}
