import Accelerate
import Foundation
import Metal
import simd
import XCTest
@testable import OpenWallpaperEngine

/// WE's HDR bloom chain (docs/lighting-plan.md §2.6, `SceneHDRChain`) on the CPU, as the GPU runs
/// WE's `hdr_downsample` and `combine_hdr` shaders: taps read with bilinear filtering and
/// clamp-to-edge, every level an RGBA16F target (each pass's output rounded to half floats), and
/// the combine written to an sRGB target (encoded and rounded to 8 bits).
enum HDRReference {
    /// An RGB image of floats, row-major.
    struct Image {
        var width: Int
        var height: Int
        var pixels: [SIMD3<Float>]

        init(width: Int, height: Int, fill: (Int, Int) -> SIMD3<Float>) {
            self.width = width
            self.height = height
            pixels = (0..<height).flatMap { y in (0..<width).map { x in fill(x, y) } }
        }

        subscript(x: Int, y: Int) -> SIMD3<Float> {
            get { pixels[y * width + x] }
            set { pixels[y * width + x] = newValue }
        }

        /// Bilinear, clamp-to-edge, at texture coordinate `uv`.
        func sample(_ uv: SIMD2<Float>) -> SIMD3<Float> {
            let x = uv.x * Float(width) - 0.5, y = uv.y * Float(height) - 0.5
            let x0 = floor(x), y0 = floor(y)
            let fx = x - x0, fy = y - y0
            func at(_ px: Float, _ py: Float) -> SIMD3<Float> {
                self[min(max(Int(px), 0), width - 1), min(max(Int(py), 0), height - 1)]
            }
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }

        /// Every pixel rounded to half floats, as an RGBA16F target stores it.
        var halved: Image {
            var copy = self
            copy.pixels = pixels.map(HDRReference.half)
            return copy
        }

        /// RGBA16F bytes, alpha 1.
        var rgba16: [UInt16] {
            HDRReference.halfBits(pixels.flatMap { [$0.x, $0.y, $0.z, 1] })
        }
    }

    static func half(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let f = floats(halfBits([value.x, value.y, value.z]))
        return SIMD3(f[0], f[1], f[2])
    }

    /// IEEE half bits of `values`, rounded to nearest even as `Float16.init` does. vImage rather than
    /// `Float16` because Swift has no `Float16` on x86_64 macOS and the tests build universal.
    static func halfBits(_ values: [Float]) -> [UInt16] {
        var input = values, output = [UInt16](repeating: 0, count: values.count)
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: src.count)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: dst.count)
                _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return output
    }

    /// Floats of IEEE half `bits`.
    static func floats(_ bits: [UInt16]) -> [Float] {
        var input = bits, output = [Float](repeating: 0, count: bits.count)
        input.withUnsafeMutableBytes { src in
            output.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: src.baseAddress, height: 1, width: vImagePixelCount(bits.count), rowBytes: src.count)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(bits.count), rowBytes: dst.count)
                _ = vImageConvert_Planar16FtoPlanarF(&s, &d, vImage_Flags(kvImageNoFlags))
            }
        }
        return output
    }

    /// `lin` of `combine_hdr` and `passthroughsrgb`.
    static func linear(_ v: SIMD3<Float>) -> SIMD3<Float> {
        func channel(_ c: Float) -> Float { c >= 0.04045 ? powf((c + 0.055) / 1.055, 2.4) : c / 12.92 }
        return SIMD3(channel(v.x), channel(v.y), channel(v.z))
    }

    /// An sRGB8 target's byte for a linear value in 0…1.
    static func srgbByte(_ c: Float) -> UInt8 {
        let c = min(max(c, 0), 1)
        let encoded = c <= 0.0031308 ? c * 12.92 : 1.055 * powf(c, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }

    /// `hdr_downsample`'s `textureBicubic` (B-spline, 4 bilinear taps), `renderVar` its `g_RenderVar0`.
    static func bicubic(_ image: Image, _ coordinate: SIMD2<Float>, renderVar: SIMD4<Float>) -> SIMD3<Float> {
        func cubic(_ v: Float) -> SIMD4<Float> {
            let n = SIMD4<Float>(1, 2, 3, 4) - v
            let s = n * n * n
            let x = s.x, y = s.y - 4 * s.x, z = s.z - 4 * s.y + 6 * s.x
            return SIMD4(x, y, z, 6 - x - y - z) * (1.0 / 6.0)
        }
        let texSize = 0.5 / SIMD2(renderVar.x, renderVar.y)
        let invTexSize = SIMD2(renderVar.x, renderVar.y) / 0.5
        var coords = coordinate * texSize - 0.5
        let fxy = coords - floor(coords)
        coords -= fxy
        let xcubic = cubic(fxy.x), ycubic = cubic(fxy.y)
        let c = SIMD4(coords.x, coords.x, coords.y, coords.y) + SIMD4(-0.5, 1.5, -0.5, 1.5)
        let s = SIMD4(xcubic.x + xcubic.y, xcubic.z + xcubic.w, ycubic.x + ycubic.y, ycubic.z + ycubic.w)
        var offset = c + SIMD4(xcubic.y, xcubic.w, ycubic.y, ycubic.w) / s
        offset *= SIMD4(invTexSize.x, invTexSize.x, invTexSize.y, invTexSize.y)
        let sample0 = image.sample(SIMD2(offset.x, offset.z)), sample1 = image.sample(SIMD2(offset.y, offset.z))
        let sample2 = image.sample(SIMD2(offset.x, offset.w)), sample3 = image.sample(SIMD2(offset.y, offset.w))
        let sx = s.x / (s.x + s.y), sy = s.z / (s.z + s.w)
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * t }
        return mix(mix(sample3, sample2, sx), mix(sample1, sample0, sx), sy)
    }

    /// The four diagonal taps of `hdr_downsample` at `uv`, bicubic or bilinear.
    static func taps(_ image: Image, _ uv: SIMD2<Float>, renderVar rv: SIMD4<Float>, bicubic cubic: Bool) -> SIMD3<Float> {
        let offsets = [SIMD2(rv.x, rv.y), SIMD2(rv.z, rv.y), SIMD2(rv.x, rv.w), SIMD2(rv.z, rv.w)]
        return offsets.reduce(SIMD3<Float>.zero) { sum, offset in
            sum + (cubic ? bicubic(image, uv + offset, renderVar: rv) : image.sample(uv + offset))
        }
    }

    /// `hdr_downsample` into a `width`×`height` target.
    static func downsample(_ source: Image, width: Int, height: Int, renderVar: SIMD4<Float>,
                           bloom: SceneHDRChain.Constants?) -> Image {
        Image(width: width, height: height) { x, y in
            let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / SIMD2(Float(width), Float(height))
            var albedo = taps(source, uv, renderVar: renderVar, bicubic: false) * 0.25
            if let bloom {
                albedo = simd_max(.zero, albedo)
                let brightness = max(albedo.x, max(albedo.y, albedo.z))
                var soft = min(max(brightness - bloom.blend.y, 0), bloom.blend.z)
                soft = soft * soft * bloom.blend.w
                var contribution = max(soft, brightness - bloom.blend.x)
                contribution /= max(brightness, 0.00001)
                albedo *= contribution * bloom.strength * bloom.tint
            }
            return half(albedo)
        }
    }

    /// The levels after the chain's downsamples and upsamples: level 0 is `_rt_2FrameBuffer`.
    static func levels(_ frame: Image, levels n: Int, constants: SceneHDRChain.Constants) -> [Image] {
        let size = SIMD2(Float(frame.width), Float(frame.height))
        let vars = SceneHDRChain.renderVars(levels: n, size: size)
        func dimensions(_ level: Int) -> (Int, Int) { BloomReference.size(frame.width, frame.height, scale: 2 << level) }
        var targets: [Image] = []
        let (w0, h0) = dimensions(0)
        targets.append(downsample(frame, width: w0, height: h0, renderVar: vars[SceneHDRChain.Pass.downsampleBloom]!,
                                  bloom: constants))
        for level in 1..<max(n, 1) {
            let (w, h) = dimensions(level)
            targets.append(downsample(targets[level - 1], width: w, height: h,
                                      renderVar: vars[SceneHDRChain.Pass.downsample(level)]!, bloom: nil))
        }
        for level in stride(from: n - 1, through: 1, by: -1) {
            let cubic = level >= n - 2
            let rv = vars[cubic ? SceneHDRChain.Pass.upsampleCubic(level) : SceneHDRChain.Pass.upsample(level)]!
            let source = targets[level]
            var target = targets[level - 1]
            for y in 0..<target.height {
                for x in 0..<target.width {
                    let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / SIMD2(Float(target.width), Float(target.height))
                    let added = taps(source, uv, renderVar: rv, bicubic: cubic) * (0.25 * constants.scatter)
                    target[x, y] = half(target[x, y] + added)
                }
            }
            targets[level - 1] = target
        }
        return targets
    }

    /// `combine_hdr_upsample` at frame pixel (x, y), as RGB bytes of the sRGB target.
    static func combined(_ frame: Image, bloom: Image, x: Int, y: Int, renderVar: SIMD2<Float> = SceneHDRChain.deviceRenderVar)
        -> SIMD3<UInt8> {
        let texel = SIMD2(1 / Float(frame.width), 1 / Float(frame.height))
        let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) * texel
        let bloom1 = (bloom.sample(uv + texel) + bloom.sample(uv - texel) + bloom.sample(uv + SIMD2(texel.x, -texel.y))
            + bloom.sample(uv + SIMD2(-texel.x, texel.y))) * 0.25
        let value = simd_clamp(linear(frame[x, y] + bloom1), .zero, SIMD3(repeating: 1)) * renderVar.x
        return SIMD3(srgbByte(value.x), srgbByte(value.y), srgbByte(value.z))
    }

    /// `combine_srgb` at frame pixel (x, y): the frame linearised, encoded again.
    static func srgbOnly(_ frame: Image, x: Int, y: Int) -> SIMD3<UInt8> {
        let value = linear(frame[x, y])
        return SIMD3(srgbByte(value.x), srgbByte(value.y), srgbByte(value.z))
    }

    /// The whole chain, as RGBA bytes; `levels` nil for `combine_srgb` alone.
    static func run(_ frame: Image, levels: Int?, constants: SceneHDRChain.Constants) -> [UInt8] {
        let bloom = levels.map { self.levels(frame, levels: $0, constants: constants)[0] }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(frame.width * frame.height * 4)
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let rgb = bloom.map { combined(frame, bloom: $0, x: x, y: y) } ?? srgbOnly(frame, x: x, y: y)
                bytes += [rgb.x, rgb.y, rgb.z, 255]
            }
        }
        return bytes
    }

    // MARK: - GPU helpers

    /// An RGBA16F texture holding `image`.
    static func texture(_ image: Image, device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: image.width,
                                                                  height: image.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let values = image.rgba16
        values.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: image.width * 8)
        }
        return texture
    }

    /// An RGBA16F texture's pixels.
    static func read(_ texture: MTLTexture, device: MTLDevice) throws -> Image {
        try OWEPhaseTiming.measure(.readback) {
            let queue = try XCTUnwrap(device.makeCommandQueue())
            let rowBytes = texture.width * 8
            let buffer = try XCTUnwrap(device.makeBuffer(length: rowBytes * texture.height, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: rowBytes, destinationBytesPerImage: rowBytes * texture.height)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            let count = texture.width * texture.height * 4
            let values = floats(Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt16.self), count: count)))
            return Image(width: texture.width, height: texture.height) { x, y in
                let i = (y * texture.width + x) * 4
                return SIMD3(values[i], values[i + 1], values[i + 2])
            }
        }
    }
}
