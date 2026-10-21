import Foundation
import simd

/// An RGBA image, 8 bits a channel, premultiplied alpha, top row first.
public struct PuppetImage: Hashable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]? = nil) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.pixels = pixels ?? [UInt8](repeating: 0, count: 4 * self.width * self.height)
    }

    public func pixel(_ x: Int, _ y: Int) -> SIMD4<UInt8> {
        guard x >= 0, y >= 0, x < width, y < height else { return .zero }
        let i = 4 * (y * width + x)
        return SIMD4(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    /// The alpha channel, for mesh generation.
    public var alphaMask: PuppetAlphaMask {
        PuppetAlphaMask(width: width, height: height, alpha: stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] })
    }

    /// Bilinear sample at texture coordinate `uv` (v down), clamped to the edges; 0…1 premultiplied.
    func sample(_ uv: SIMD2<Float>) -> SIMD4<Float> {
        guard width > 0, height > 0 else { return .zero }
        let x = uv.x * Float(width) - 0.5, y = uv.y * Float(height) - 0.5
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Float(x0), fy = y - Float(y0)
        func texel(_ px: Int, _ py: Int) -> SIMD4<Float> {
            let cx = min(max(px, 0), width - 1), cy = min(max(py, 0), height - 1)
            let i = 4 * (cy * width + cx)
            return SIMD4(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2]), Float(pixels[i + 3])) / 255
        }
        let top = texel(x0, y0) * (1 - fx) + texel(x0 + 1, y0) * fx
        let bottom = texel(x0, y0 + 1) * (1 - fx) + texel(x0 + 1, y0 + 1) * fx
        return top * (1 - fy) + bottom * fy
    }
}

/// Where the mesh's space lands in an image: pixel = (x − origin.x, origin.y − y) · scale.
public struct PuppetRasterViewport: Hashable, Sendable {
    /// The mesh point at the image's top-left corner.
    public var origin: SIMD2<Float>
    /// Image pixels per mesh unit.
    public var scale: Float
    public var width: Int
    public var height: Int

    public init(origin: SIMD2<Float>, scale: Float, width: Int, height: Int) {
        self.origin = origin
        self.scale = scale
        self.width = width
        self.height = height
    }

    /// A viewport over `bounds` (mesh space) at `scale`, a pixel of margin around it.
    public init(bounds: (min: SIMD2<Float>, max: SIMD2<Float>), scale: Float) {
        let margin = 1 / max(scale, 1e-6)
        origin = SIMD2(bounds.min.x - margin, bounds.max.y + margin)
        self.scale = scale
        width = max(1, Int(((bounds.max.x - bounds.min.x + 2 * margin) * scale).rounded(.up)))
        height = max(1, Int(((bounds.max.y - bounds.min.y + 2 * margin) * scale).rounded(.up)))
    }

    public func pixel(_ p: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2((p.x - origin.x) * scale, (origin.y - p.y) * scale)
    }
}

/// Draws a posed mesh on the CPU: each triangle textured from the image at its texture
/// coordinates (bilinear) and laid over the triangles before it, as the albedo draw composites
/// them (docs/models-plan.md §2.13). The editor's preview and the tests use it; the wallpaper
/// itself is drawn by the app's renderer.
public enum PuppetRasterizer {
    /// The mesh at `positions` (mesh space, one per vertex) textured from `texture`.
    public static func render(_ document: PuppetDocument, positions: [SIMD2<Float>], texture: PuppetImage,
                              viewport: PuppetRasterViewport) -> PuppetImage {
        var image = PuppetImage(width: viewport.width, height: viewport.height)
        let points = positions.map(viewport.pixel)
        for triangle in document.mesh.triangles {
            let ids = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
            guard ids.allSatisfy({ $0 < points.count && $0 < document.mesh.vertices.count }) else { continue }
            let uv = ids.map { document.mesh.vertices[$0].uv }
            fill(&image, ids.map { points[$0] }) { b in
                texture.sample(uv[0] * b.x + uv[1] * b.y + uv[2] * b.z)
            }
        }
        return image
    }

    /// A heat map of one bone's weights over the posed mesh: blue (0) through green to red (1),
    /// interpolated across each triangle, at `opacity`.
    public static func renderWeights(_ document: PuppetDocument, positions: [SIMD2<Float>], bone: Int,
                                     viewport: PuppetRasterViewport, opacity: Float = 0.6) -> PuppetImage {
        var image = PuppetImage(width: viewport.width, height: viewport.height)
        let points = positions.map(viewport.pixel)
        let weights = document.mesh.vertices.indices.map { index in
            index < document.weights.count ? PuppetWeight.weight(of: bone, in: document.weights[index]) : 0
        }
        for triangle in document.mesh.triangles {
            let ids = [Int(triangle.x), Int(triangle.y), Int(triangle.z)]
            guard ids.allSatisfy({ $0 < points.count }) else { continue }
            let w = ids.map { weights[$0] }
            fill(&image, ids.map { points[$0] }, blend: false) { b in
                heatColor(w[0] * b.x + w[1] * b.y + w[2] * b.z) * opacity
            }
        }
        return image
    }

    /// The heat map's colour for a weight, opaque, premultiplied.
    public static func heatColor(_ weight: Float) -> SIMD4<Float> {
        let t = min(max(weight, 0), 1)
        // Blue → cyan → green → yellow → red.
        let stops: [SIMD3<Float>] = [SIMD3(0.10, 0.15, 0.85), SIMD3(0.0, 0.75, 0.95), SIMD3(0.1, 0.85, 0.25),
                                     SIMD3(0.98, 0.85, 0.1), SIMD3(0.95, 0.15, 0.1)]
        let scaled = t * Float(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let f = scaled - Float(index)
        let rgb = stops[index] * (1 - f) + stops[index + 1] * f
        return SIMD4(rgb, 1)
    }

    /// Fills a triangle (pixel space) with `shade(barycentric)`, composited over the image (or,
    /// without `blend`, replacing it). A pixel on an edge two triangles share is filled once.
    static func fill(_ image: inout PuppetImage, _ p: [SIMD2<Float>], blend: Bool = true,
                     shade: (SIMD3<Float>) -> SIMD4<Float>) {
        var a = p[0], b = p[1], c = p[2]
        var area = PuppetMath.cross(b - a, c - a)
        guard abs(area) > 1e-9, area.isFinite else { return }
        if area < 0 {
            swap(&b, &c)
            area = -area
        }
        let low = simd_max(simd_min(simd_min(a, b), c).rounded(.down), .zero)
        let high = simd_min(simd_max(simd_max(a, b), c).rounded(.up), SIMD2(Float(image.width), Float(image.height)))
        guard low.x < high.x, low.y < high.y else { return }
        func edge(_ u: SIMD2<Float>, _ v: SIMD2<Float>, _ q: SIMD2<Float>) -> Float { PuppetMath.cross(v - u, q - u) }
        // Fill rule: a pixel exactly on an edge belongs to one side only.
        func owns(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Bool { let d = v - u; return d.y > 0 || (d.y == 0 && d.x < 0) }
        let ownsA = owns(b, c), ownsB = owns(c, a), ownsC = owns(a, b)
        let swapped = p[1] != b
        for y in Int(low.y)..<Int(high.y) {
            for x in Int(low.x)..<Int(high.x) {
                let q = SIMD2(Float(x) + 0.5, Float(y) + 0.5)
                let w0 = edge(b, c, q), w1 = edge(c, a, q), w2 = edge(a, b, q)
                guard w0 > 0 || (w0 == 0 && ownsA), w1 > 0 || (w1 == 0 && ownsB), w2 > 0 || (w2 == 0 && ownsC) else { continue }
                var bary = SIMD3(w0, w1, w2) / area
                if swapped { bary = SIMD3(bary.x, bary.z, bary.y) }
                let colour = shade(bary)
                let i = 4 * (y * image.width + x)
                if blend {
                    let dst = SIMD4(Float(image.pixels[i]), Float(image.pixels[i + 1]), Float(image.pixels[i + 2]),
                                    Float(image.pixels[i + 3])) / 255
                    let out = colour + dst * (1 - colour.w)
                    store(&image, i, out)
                } else {
                    store(&image, i, colour)
                }
            }
        }
    }

    private static func store(_ image: inout PuppetImage, _ i: Int, _ colour: SIMD4<Float>) {
        let clamped = simd_min(simd_max(colour, .zero), SIMD4(repeating: 1)) * 255
        image.pixels[i] = UInt8(clamped.x.rounded())
        image.pixels[i + 1] = UInt8(clamped.y.rounded())
        image.pixels[i + 2] = UInt8(clamped.z.rounded())
        image.pixels[i + 3] = UInt8(clamped.w.rounded())
    }
}
