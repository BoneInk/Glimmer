import simd
@testable import OpenWallpaperEngine

/// A CPU model of WE's volumetrics passes (docs/lighting-plan.md §2.8), to check the translated
/// shaders against: `volumetrics_front` along one pixel's ray, and the blur and combine.
enum VolumetricsReference {
    /// An RGBA float image, rows as stored (row 0 first).
    struct Image {
        var width: Int
        var height: Int
        var pixels: [SIMD4<Float>]

        init(width: Int, height: Int, pixel: (Int, Int) -> SIMD4<Float>) {
            self.width = width
            self.height = height
            pixels = (0..<(width * height)).map { pixel($0 % width, $0 / width) }
        }

        init(bytes: [UInt8], width: Int, height: Int) {
            self.init(width: width, height: height) { x, y in
                let i = (y * width + x) * 4
                return SIMD4(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2]), Float(bytes[i + 3])) / 255
            }
        }

        subscript(x: Int, y: Int) -> SIMD4<Float> {
            pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        /// Rounded to 8 bits, as an RGBA8 target stores it.
        var quantized: Image {
            var copy = self
            copy.pixels = pixels.map { (simd_clamp($0, .zero, SIMD4(repeating: 1)) * 255).rounded(.toNearestOrAwayFromZero) / 255 }
            return copy
        }

        var bytes: [UInt8] {
            var bytes: [UInt8] = []
            for pixel in pixels {
                for channel in 0..<4 { bytes.append(UInt8((min(max(pixel[channel], 0), 1) * 255).rounded())) }
            }
            return bytes
        }
    }

    // MARK: - Blur and combine

    /// `blur_k3` (`common_blur.h` `blur3`): 1/4, 1/2, 1/4 at ±1 texel, clamped at the edges, alpha 1.
    static func blur3(_ image: Image, vertical: Bool) -> Image {
        Image(width: image.width, height: image.height) { x, y in
            let (dx, dy) = vertical ? (0, 1) : (1, 0)
            let sum = image[x + dx, y + dy] * 0.25 + image[x, y] * 0.5 + image[x - dx, y - dy] * 0.25
            return SIMD4(sum.x, sum.y, sum.z, 1)
        }.quantized
    }

    /// WE's finish: `blurs` runs `volumetrics_blur_h` then `_v` (through an RGBA8 target), and
    /// `volumetrics_combine` adds the light buffer to the scene (`passthrough`, additive).
    static func finish(scene: Image, lightBuffer: Image, blurs: Bool) -> Image {
        var light = lightBuffer
        if blurs { light = blur3(blur3(light, vertical: false), vertical: true) }
        return Image(width: scene.width, height: scene.height) { x, y in
            let add = light[x, y]
            return simd_clamp(scene[x, y] + SIMD4(add.x * add.w, add.y * add.w, add.z * add.w, add.w), .zero, SIMD4(repeating: 1))
        }.quantized
    }

    // MARK: - The ray march

    /// Where one light-buffer pixel's ray meets the volume: the near faces (the front pass's
    /// mesh) and the far ones (the back pass's), as clip depth; nil where it misses.
    struct Hit {
        var near: Float
        var far: Float
    }

    /// Rasterises `mesh` at WE clip-space point (`x`, `y`): the smallest and largest clip depth of
    /// the triangles covering it. `scale` is the front vertex shader's (0.99, 0.99, 1) for spots.
    static func depths(of mesh: SceneVolumeMesh, transform: simd_float4x4, x: Float, y: Float,
                       scale: SIMD3<Float> = SIMD3(repeating: 1)) -> (min: Float, max: Float)? {
        let projected = mesh.positions.map { position -> SIMD3<Float> in
            let clip = transform * SIMD4(position * scale, 1)
            return SIMD3(clip.x, clip.y, clip.z) / clip.w
        }
        var nearest = Float.infinity, farthest = -Float.infinity
        for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
            let a = projected[Int(mesh.indices[triangle])], b = projected[Int(mesh.indices[triangle + 1])]
            let c = projected[Int(mesh.indices[triangle + 2])]
            let area = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            guard abs(area) > 1e-12 else { continue }
            let w0 = ((b.x - x) * (c.y - y) - (b.y - y) * (c.x - x)) / area
            let w1 = ((c.x - x) * (a.y - y) - (c.y - y) * (a.x - x)) / area
            let w2 = 1 - w0 - w1
            guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
            let depth = w0 * a.z + w1 * b.z + w2 * c.z
            nearest = min(nearest, depth)
            farthest = max(farthest, depth)
        }
        return nearest.isFinite ? (nearest, farthest) : nil
    }

    /// `volumetricsfront.frag` for a light without a cookie or a shadow, at WE clip point (`x`,
    /// `y`), ray-marching from `near` to the nearer of `far` and the scene's depth (the far plane).
    /// Depth is reversed (`REVERSEDEPTH`): the far plane is 0, and nearer is greater.
    static func march(_ light: SceneVolumetricLight, point: Bool, viewProjection: simd_float4x4, x: Float, y: Float,
                      near: Float, far: Float, quality: Int,
                      fog: SceneFogSettings? = nil, eye: SIMD3<Float> = .zero) -> SIMD3<Float> {
        let sampleCount: Float = [1: 2, 2: 3, 3: 5, 4: 8][quality] ?? 2
        let inverse = viewProjection.inverse
        func world(_ depth: Float) -> SIMD3<Float> {
            let p = inverse * SIMD4(x, y, depth, 1)
            return SIMD3(p.x, p.y, p.z) / p.w
        }
        let spot = light.renderVars[1], origin = light.renderVars[2], forward = light.renderVars[3]
        let color = light.renderVars[4]
        var position = world(near)
        let end = world(max(0, far))
        let step = (end - position) / (sampleCount + 1)
        let invRadius = 1 / spot.x
        var maxLightScale = spot.w * simd_length(end - position) * invRadius
        if point { maxLightScale *= 0.5 }
        var factor: Float = 0
        for _ in 0..<Int(sampleCount) {
            position += step
            let delta = position - SIMD3(origin.x, origin.y, origin.z)
            let falloff = pow(simd_clamp(1 - simd_length(delta) * invRadius, 0, 1), color.w)
            var cone: Float = 1
            if !point {
                let cosine = simd_dot(simd_normalize(delta), SIMD3(forward.x, forward.y, forward.z))
                let t = simd_clamp((cosine - spot.z) / (spot.y - spot.z), 0, 1)
                cone = t * t * (3 - 2 * t)
            }
            var sample = falloff * cone
            if let fog, fog.distance || fog.height {
                // `common_fog.h`'s ApplyFogAlpha, which the shader multiplies into the sample it
                // was given: `shadowSample *= ApplyFogAlpha(shadowSample, …)`.
                func curve(_ state: Float, _ params: SIMD4<Float>) -> Float {
                    let t = simd_clamp(state, 0, 1)
                    return params.z + params.w * t * t
                }
                let distance = fog.distance
                    ? curve((simd_length(eye - position) - fog.distanceParams.x) / fog.distanceParams.y, fog.distanceParams) : 0
                let height = fog.height
                    ? curve((position.y - fog.heightParams.x) / fog.heightParams.y, fog.heightParams) : 0
                let fogFactor = simd_clamp(max(distance, height), 0, 1)
                sample *= sample * (1 - fogFactor * fogFactor)
            }
            factor += sample
        }
        factor /= sampleCount
        return origin.w * maxLightScale * factor * SIMD3(color.x, color.y, color.z) * 0.1
    }
}
