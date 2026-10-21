import Metal

/// Turns a HDR video's decoded frames into the scene's linear BT.709 light (`VideoTextureStream`
/// in HDR mode).
///
/// AVFoundation decodes a PQ or HLG video to linear half floats in BT.2020 without changing its
/// range (1.0 = 100 nits, a 1000-nit highlight 10.0); asked for BT.709 it tone maps the frame
/// into 0…1 instead, which would lose the HDR. So the frame is decoded in BT.2020 and this pass
/// converts its primaries, once per new video frame, on the frame's command buffer.
final class VideoHDRConversion {
    private let pipeline: MTLComputePipelineState
    private let device: MTLDevice
    /// The converted frame. One is enough: it is tracked, so Metal orders each rewrite after the
    /// frames already encoded that sample it.
    private var converted: MTLTexture?

    /// Nil (logged) when the engine's Metal library or the kernel's pipeline can't be made.
    init?(device: MTLDevice) {
        guard let library = SceneMetalLibrary.make(device: device) else { return nil }
        guard let function = library.makeFunction(name: "videoHDRToLinear709") else {
            OWELog.error(.scene, "The HDR video conversion kernel is missing from the engine's Metal library")
            return nil
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            OWELog.error(.scene, "The HDR video conversion pipeline can't be made: \(error)")
            return nil
        }
        self.device = device
    }

    /// Encodes `source` (linear BT.2020) into the converted frame (linear BT.709, RGBA16F) and
    /// returns it; nil when it can't be made.
    func encode(_ source: MTLTexture, on commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let target = target(width: source.width, height: source.height),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }
        encoder.label = "HDR video to linear BT.709"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        let width = pipeline.threadExecutionWidth
        let group = MTLSize(width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
        let groups = MTLSize(width: (source.width + group.width - 1) / group.width,
                             height: (source.height + group.height - 1) / group.height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        encoder.endEncoding()
        return target
    }

    private func target(width: Int, height: Int) -> MTLTexture? {
        if let converted, converted.width == width, converted.height == height { return converted }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            OWELog.error(.scene, "Could not make a \(width)×\(height) HDR video frame")
            return nil
        }
        texture.label = "HDR video frame"
        converted = texture
        return texture
    }
}
