import Foundation
import simd
@testable import OWESceneEditing

/// Synthetic images and rigs for the puppet tests.
enum PuppetFixtures {
    /// A `width × height` mask, opaque where `inside(x, y)` (pixel centres, y down).
    static func mask(width: Int, height: Int, inside: (Float, Float) -> Bool) -> PuppetAlphaMask {
        var alpha = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width where inside(Float(x) + 0.5, Float(y) + 0.5) { alpha[y * width + x] = 255 }
        }
        return PuppetAlphaMask(width: width, height: height, alpha: alpha)
    }

    /// A "C": a ring with a notch cut out of its right side.
    static func cShape(size: Int = 200) -> PuppetAlphaMask {
        let centre = Float(size) / 2
        return mask(width: size, height: size) { x, y in
            let d = simd_distance(SIMD2(x, y), SIMD2(centre, centre))
            let inRing = d <= Float(size) * 0.45 && d >= Float(size) * 0.2
            let inNotch = x > centre && abs(y - centre) < Float(size) * 0.1
            return inRing && !inNotch
        }
    }

    /// An opaque image of one colour.
    static func solidImage(width: Int, height: Int, colour: SIMD4<UInt8> = SIMD4(255, 255, 255, 255)) -> PuppetImage {
        var pixels = [UInt8]()
        pixels.reserveCapacity(4 * width * height)
        for _ in 0..<(width * height) { pixels += [colour.x, colour.y, colour.z, colour.w] }
        return PuppetImage(width: width, height: height, pixels: pixels)
    }

    /// A vertical strip `width × height` (mesh space x ∈ ±width/2, y ∈ ±height/2) as a grid of
    /// `rows` quads, with two bones: `lower` at the bottom pointing up, `upper` at the middle.
    /// The lower half is weighted to `lower`, the upper half to `upper`, the middle row shared.
    static func twoBoneStrip(width: Float = 20, height: Float = 200, rows: Int = 10) -> PuppetDocument {
        var document = PuppetDocument.new(imageSize: SIMD2(width, height), material: "materials/strip.json")
        document.bones = []
        var vertices: [PuppetVertex] = []
        for row in 0...rows {
            let y = -height / 2 + height * Float(row) / Float(rows)
            for x in [-width / 2, width / 2] {
                let p = SIMD2(x, y)
                vertices.append(PuppetVertex(position: p, uv: document.textureCoordinate(of: p)))
            }
        }
        var triangles: [SIMD3<UInt32>] = []
        for row in 0..<rows {
            let a = UInt32(2 * row), b = a + 1, c = a + 2, d = a + 3
            triangles.append(SIMD3(a, b, d))
            triangles.append(SIMD3(a, d, c))
        }
        document.replaceMesh(PuppetMesh(vertices: vertices, triangles: triangles))
        // Bones point up (+90°): x along the strip.
        document.addBone(named: "lower", parent: nil, head: SIMD2(0, -height / 2), angle: .pi / 2)
        document.addBone(named: "upper", parent: 0, head: SIMD2(0, 0), angle: .pi / 2)
        document.weights = vertices.map { vertex in
            if abs(vertex.position.y) < 1e-3 {
                return [PuppetWeight(bone: 0, weight: 0.5), PuppetWeight(bone: 1, weight: 0.5)]
            }
            return [PuppetWeight(bone: vertex.position.y < 0 ? 0 : 1, weight: 1)]
        }
        return document
    }
}
