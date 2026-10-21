import Foundation
import simd

/// WE's LDR bloom chain (docs/lighting-plan.md §2.6) on the CPU, as the GPU runs WE's shaders:
/// taps read with bilinear filtering and clamp-to-edge, `g_TexelSize` = 1 / the frame's size, and
/// every target RGBA8, so each pass's output is rounded to 8 bits.
enum BloomReference {
    /// An RGB image, row-major, values in 0…1.
    struct Image {
        var width: Int
        var height: Int
        var pixels: [SIMD3<Float>]

        init(width: Int, height: Int, pixels: [SIMD3<Float>]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        init(width: Int, height: Int, fill: (Int, Int) -> SIMD3<Float>) {
            self.width = width
            self.height = height
            pixels = (0..<height).flatMap { y in (0..<width).map { x in fill(x, y) } }
        }

        /// RGBA bytes (alpha ignored), or BGRA with `bgra`.
        init(bytes: [UInt8], width: Int, height: Int, bgra: Bool = false) {
            self.init(width: width, height: height) { x, y in
                let i = (y * width + x) * 4
                let rgb = SIMD3(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
                return bgra ? SIMD3(rgb.z, rgb.y, rgb.x) : rgb
            }
        }

        subscript(x: Int, y: Int) -> SIMD3<Float> { pixels[y * width + x] }

        /// RGBA bytes, alpha 255.
        var rgba: [UInt8] {
            pixels.flatMap { pixel -> [UInt8] in
                let byte = BloomReference.quantized(pixel) * 255
                return [UInt8(byte.x.rounded()), UInt8(byte.y.rounded()), UInt8(byte.z.rounded()), 255]
            }
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
    }

    /// The blur weights of `downsample_eighth_blur_v` and `blur_h_bloom`, taps −6…6.
    static let weights: [Float] = [0.006299, 0.017298, 0.039533, 0.075189, 0.119007, 0.156756, 0.171834,
                                   0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299]

    /// An RGBA8 target's value.
    static func quantized(_ value: SIMD3<Float>) -> SIMD3<Float> {
        (simd_clamp(value, .zero, SIMD3(repeating: 1)) * 255).rounded(.toNearestOrEven) / 255
    }

    /// An effect FBO's size at `scale` (`EffectGraphRenderer.fboSize`).
    static func size(_ width: Int, _ height: Int, scale: Int) -> (Int, Int) {
        (max(Int((Double(width) / Double(scale)).rounded()), 1), max(Int((Double(height) / Double(scale)).rounded()), 1))
    }

    /// Passes 1–3: `_rt_Bloom`.
    static func bloom(_ frame: Image, strength: Float, threshold: Float, tint: SIMD3<Float>) -> Image {
        let texel = SIMD2<Float>(1 / Float(frame.width), 1 / Float(frame.height))
        // 1. downsample_quarter_bloom → _rt_4FrameBuffer.
        let (qw, qh) = size(frame.width, frame.height, scale: 4)
        let quarter = Image(width: qw, height: qh) { x, y in
            let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / SIMD2(Float(qw), Float(qh))
            var albedo = frame.sample(uv - texel) + frame.sample(uv + texel)
                + frame.sample(uv + SIMD2(-texel.x, texel.y)) + frame.sample(uv + SIMD2(texel.x, -texel.y))
            albedo *= 0.25
            let scale = max(max(albedo.x, albedo.y), albedo.z)
            albedo *= min(max(scale - threshold, 0), 1)
            let grayscale = dot(SIMD3<Float>(0.2989, 0.5870, 0.1140), albedo)
            albedo = -grayscale + albedo * 2
            return quantized(simd_max(.zero, albedo * strength * tint))
        }
        // 2. downsample_eighth_blur_v → _rt_8FrameBuffer: 13 taps along x, 8 frame texels apart.
        let (ew, eh) = size(frame.width, frame.height, scale: 8)
        let eighth = blur(quarter, width: ew, height: eh, step: SIMD2(texel.x * 8, 0))
        // 3. blur_h_bloom → _rt_Bloom: the same along y.
        return blur(eighth, width: ew, height: eh, step: SIMD2(0, texel.y * 8))
    }

    private static func blur(_ source: Image, width: Int, height: Int, step: SIMD2<Float>) -> Image {
        Image(width: width, height: height) { x, y in
            let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / SIMD2(Float(width), Float(height))
            var sum = SIMD3<Float>.zero
            for (index, weight) in weights.enumerated() {
                sum += source.sample(uv + step * Float(index - 6)) * weight
            }
            return quantized(sum)
        }
    }

    /// Pass 4, `combine`, at frame pixel (x, y).
    static func combined(_ frame: Image, bloom: Image, x: Int, y: Int) -> SIMD3<Float> {
        let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) / SIMD2(Float(frame.width), Float(frame.height))
        return quantized(frame[x, y] + bloom.sample(uv))
    }

    /// The whole chain.
    static func run(_ frame: Image, strength: Float, threshold: Float, tint: SIMD3<Float>) -> Image {
        let bloom = bloom(frame, strength: strength, threshold: threshold, tint: tint)
        return Image(width: frame.width, height: frame.height) { x, y in combined(frame, bloom: bloom, x: x, y: y) }
    }
}
