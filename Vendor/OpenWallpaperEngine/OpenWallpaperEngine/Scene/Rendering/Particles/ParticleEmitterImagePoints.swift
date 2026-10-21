import Foundation
import Metal
import simd

/// The points a `layerimage` emitter picks among, made from its layer's image as `wallpaper64.exe`
/// makes them (0x1401d3ae0):
/// - The image (its texture's own size, w × h) is drawn through `materials/util/downsample_quarter.json`
///   with `WRITEALPHA` into a target a quarter its size, at least 2 × 2; an image larger than
///   3840 × 2160 is first fitted into it, keeping its aspect (0x1401d3caa…0x1401d3d7e). The shader
///   averages four bilinear samples two texels from the target texel's centre.
/// - The target is read back, and every texel whose alpha is at least 127 becomes a point: its
///   colour, and its centre in the image's pixels from the image's centre,
///   `trunc(s·(i + ½) − ⌊w/2⌋)` across and the same down, with `s` = w ÷ the target's width
///   (0x1401d411d…0x1401d41b2). The spawn negates the row (y up, 0x1402397ee).
///
/// The spawn picks one of the points at random (0x140238f2f) and places the particle there in the
/// layer's space (`ParticleFrameInputs`' image transform).
///
/// On a Puppet Warp layer each point also takes a bone (`ParticleEmitterImageBones`). With flag
/// 0x20000 the layer is sampled again once a second of emitting (`ParticleEmitterImageResampler`).
enum ParticleEmitterImagePoints {
    /// The smallest alpha a texel of the reduced image needs to become a point (0x1401d411d).
    static let minimumAlpha: UInt8 = 0x7f

    /// The reduced image's size for an image of `size` pixels.
    static func targetSize(imageSize size: SIMD2<Int>) -> SIMD2<Int> {
        var width = size.x, height = size.y
        if width > 3840 || height > 2160 {
            let aspect = Float(width) / Float(max(height, 1))
            if aspect >= 1920.0 / 1080.0 {
                width = 3840
                height = Int(3840 / aspect)
            } else {
                height = 2160
                width = Int(2160 * aspect)
            }
        }
        // C's signed division by four, at least 2.
        return SIMD2(max(width / 4, 2), max(height / 4, 2))
    }

    /// The points of a reduced image: `rgba` holds `target` texels, row by row from the top;
    /// `imageSize` is the image's own size in pixels.
    static func points(rgba: [UInt8], target: SIMD2<Int>, imageSize: SIMD2<Int>) -> [SIMD4<Int32>] {
        let scale = Float(imageSize.x) / Float(target.x)
        let halfWidth = Float(imageSize.x >> 1), halfHeight = Float(imageSize.y >> 1)
        var points: [SIMD4<Int32>] = []
        for column in 0..<target.x {
            for row in 0..<target.y {
                let texel = (row * target.x + column) * 4
                guard texel + 3 < rgba.count, rgba[texel + 3] >= minimumAlpha else { continue }
                let x = Int32(scale * Float(column) - halfWidth + scale * 0.5)
                let y = Int32(scale * Float(row) - halfHeight + scale * 0.5)
                let color = Int32(rgba[texel]) << 16 | Int32(rgba[texel + 1]) << 8 | Int32(rgba[texel + 2])
                points.append(SIMD4(x, -y, color, 0))
            }
        }
        return points
    }

    /// Where the reduction reads a layer's image: its texture, the content's UV origin in it and
    /// the content's UV axes (a frame of a sprite sheet, a padded texture's share).
    struct Sampling {
        var texture: MTLTexture
        var uvOrigin = SIMD2<Float>.zero
        var uvAxisX = SIMD2<Float>(1, 0)
        var uvAxisY = SIMD2<Float>(0, 1)

        /// The content filling `uvExtent` of `texture` from its origin.
        init(texture: MTLTexture, uvExtent: SIMD2<Float> = SIMD2(1, 1)) {
            self.texture = texture
            uvAxisX = SIMD2(uvExtent.x, 0)
            uvAxisY = SIMD2(0, uvExtent.y)
        }

        init(texture: MTLTexture, uvOrigin: SIMD2<Float>, uvAxisX: SIMD2<Float>, uvAxisY: SIMD2<Float>) {
            self.texture = texture
            self.uvOrigin = uvOrigin
            self.uvAxisX = uvAxisX
            self.uvAxisY = uvAxisY
        }
    }

    /// The reduction's pipeline on `device`.
    static func reducePipeline(device: MTLDevice) throws -> MTLComputePipelineState {
        let library = try SceneMetalLibrary.load(device: device)
        guard let function = library.makeFunction(name: "particleEmitterImageReduce") else { throw ReduceError.noFunction }
        return try device.makeComputePipelineState(function: function)
    }

    /// Encodes the reduction of `sampling` into `commands`, written as RGBA8 rows from the top into
    /// the returned buffer once they complete.
    static func encodeReduce(_ sampling: Sampling, target: SIMD2<Int>, pipeline: MTLComputePipelineState,
                             into commands: MTLCommandBuffer) throws -> MTLBuffer {
        let texture = sampling.texture
        guard let output = commands.device.makeBuffer(length: target.x * target.y * 4, options: .storageModeShared),
              let encoder = commands.makeComputeCommandEncoder() else { throw ReduceError.allocation }
        output.label = "Particle layer image reduction"
        var parameters = (SIMD4<Float>(sampling.uvOrigin.x, sampling.uvOrigin.y, 1 / Float(texture.width), 1 / Float(texture.height)),
                          SIMD4<Float>(sampling.uvAxisX.x, sampling.uvAxisX.y, sampling.uvAxisY.x, sampling.uvAxisY.y))
        var size = SIMD2<UInt32>(UInt32(target.x), UInt32(target.y))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: 2 * MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: (target.x + 7) / 8, height: (target.y + 7) / 8, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        return output
    }

    /// The bytes of a completed reduction (`encodeReduce`).
    static func bytes(of output: MTLBuffer) -> [UInt8] {
        Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self), count: output.length))
    }

    /// The reduced image of `sampling` as RGBA8 rows from the top: the downsample drawn on the GPU
    /// and read back once, waiting for it (the load, off the render thread). Nil (logged) when the
    /// GPU can't run it.
    static func reduce(_ sampling: Sampling, target: SIMD2<Int>, device: MTLDevice, queue: MTLCommandQueue) -> [UInt8]? {
        ThreadGuards.assertNotRenderThread("ParticleEmitterImagePoints.reduce")
        do {
            let pipeline = try reducePipeline(device: device)
            guard let commands = queue.makeCommandBuffer() else { throw ReduceError.allocation }
            let output = try encodeReduce(sampling, target: target, pipeline: pipeline, into: commands)
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
            return bytes(of: output)
        } catch {
            OWELog.error(.scene, "A layerimage emitter's layer image can't be reduced on the GPU: \(error)")
            return nil
        }
    }

    /// A layer's image as the points are made from it: where its picture is in its texture, the
    /// image's own size in pixels, and a Puppet Warp layer's rig.
    struct Source {
        var sampling: Sampling
        var imageSize: SIMD2<Int>
        var rig: ParticleEmitterImageBones.Rig?
    }

    /// The points of `rgba` (`points(rgba:…)`), each with its bone on a rigged layer.
    static func points(rgba: [UInt8], target: SIMD2<Int>, imageSize: SIMD2<Int>,
                       rig: ParticleEmitterImageBones.Rig?) -> [SIMD4<Int32>] {
        var points = points(rgba: rgba, target: target, imageSize: imageSize)
        if let rig { ParticleEmitterImageBones.assign(&points, rig: rig) }
        return points
    }

    /// Samples each of `images`' layers (`sources`, by object id) into its points; a layer
    /// without a source (not an image layer, or missing) keeps none. Each layer is reduced once.
    static func fill(_ images: inout [ParticleEmitterImage], sources: [String: Source], device: MTLDevice,
                     queue: MTLCommandQueue, cache: inout [String: [SIMD4<Int32>]]) {
        for index in images.indices {
            let id = images[index].layerID
            if let cached = cache[id] {
                images[index].points = cached
                continue
            }
            guard let source = sources[id], source.imageSize.x > 0, source.imageSize.y > 0 else {
                if !id.isEmpty { OWELog.error(.scene, "A layerimage emitter's layer \(id) has no image; it emits nothing") }
                cache[id] = []
                continue
            }
            let target = targetSize(imageSize: source.imageSize)
            let rgba = reduce(source.sampling, target: target, device: device, queue: queue) ?? []
            let points = points(rgba: rgba, target: target, imageSize: source.imageSize, rig: source.rig)
            cache[id] = points
            images[index].points = points
        }
    }

    private enum ReduceError: Error {
        case noFunction, allocation
    }
}
