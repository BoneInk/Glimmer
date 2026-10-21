import Foundation
import simd

/// The Glass shatter (23) mesh, as WE's `CreateVoronoiFacets` makes it: the target's [-1, 1]²
/// cut into Voronoi cells, each a front face at z = 0 plus thin sides reaching back to z < 0. Every
/// vertex carries its cell's centre (`a_Center`), which the vertex shader moves and spins the piece
/// around, and a normal (`a_Normal`) for the lighting. The pieces are laid out deterministically
/// from `seed`, so the mesh is built once per renderer and tests see the same one every time.
enum WallpaperTransitionFacets {
    /// One vertex, laid out as the shader's `FacetVertex` (11 packed floats).
    struct Vertex {
        var position: (x: Float, y: Float, z: Float)
        var texCoord: (u: Float, v: Float)
        var center: (x: Float, y: Float, z: Float)
        var normal: (x: Float, y: Float, z: Float)
    }

    /// Seeds per row and column: about 80 pieces, roughly square on a 16:9 screen.
    static let columns = 10
    static let rows = 8
    /// How far the sides reach back. The shader tells front from back by z < -0.0001.
    static let depth: Float = 0.02
    static let defaultSeed: UInt64 = 0x5EED_0F_FACE7

    /// Triangles (a plain list): each cell's sides, then its front face over them.
    static func make(seed: UInt64 = defaultSeed) -> [Vertex] {
        let sites = jitteredSites(seed: seed)
        var vertices: [Vertex] = []
        vertices.reserveCapacity(sites.count * 60)
        for index in sites.indices {
            let cell = voronoiCell(of: index, sites: sites)
            guard cell.count >= 3 else { continue }
            appendCell(cell, to: &vertices)
        }
        return vertices
    }

    /// One site per grid cell, at a random point inside its middle 70%.
    static func jitteredSites(seed: UInt64) -> [SIMD2<Double>] {
        var generator = SplitMix64(state: seed)
        var sites: [SIMD2<Double>] = []
        sites.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let jitter = SIMD2<Double>(0.15 + 0.7 * generator.nextUnit(), 0.15 + 0.7 * generator.nextUnit())
                let cell = SIMD2<Double>(Double(column), Double(row)) + jitter
                sites.append(SIMD2<Double>(cell.x / Double(columns) * 2 - 1, cell.y / Double(rows) * 2 - 1))
            }
        }
        return sites
    }

    /// The cell of `sites[index]`: the square clipped by the half-plane nearer to it than to each
    /// other site. Counter-clockwise (y up), like the square it starts from.
    static func voronoiCell(of index: Int, sites: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var polygon: [SIMD2<Double>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
        let site = sites[index]
        for (other, otherSite) in sites.enumerated() where other != index {
            let normal = otherSite - site
            let offset = simd_dot(normal, (site + otherSite) * 0.5)
            polygon = clip(polygon, keepingBelow: normal, offset: offset)
            if polygon.isEmpty { break }
        }
        return polygon
    }

    /// Sutherland–Hodgman against dot(normal, p) <= offset.
    private static func clip(_ polygon: [SIMD2<Double>], keepingBelow normal: SIMD2<Double>, offset: Double) -> [SIMD2<Double>] {
        var result: [SIMD2<Double>] = []
        result.reserveCapacity(polygon.count + 1)
        for (index, current) in polygon.enumerated() {
            let next = polygon[(index + 1) % polygon.count]
            let currentSide = simd_dot(normal, current) - offset
            let nextSide = simd_dot(normal, next) - offset
            if currentSide <= 0 { result.append(current) }
            if (currentSide < 0) != (nextSide < 0), currentSide != nextSide {
                let t = currentSide / (currentSide - nextSide)
                result.append(current + (next - current) * t)
            }
        }
        return result
    }

    private static func appendCell(_ cell: [SIMD2<Double>], to vertices: inout [Vertex]) {
        let points = cell.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        var centroid = SIMD2<Float>(0, 0)
        for point in points { centroid += point }
        centroid /= Float(points.count)
        let center = (x: centroid.x, y: centroid.y, z: Float(0))

        func vertex(_ point: SIMD2<Float>, z: Float, normal: (x: Float, y: Float, z: Float)) -> Vertex {
            // The texel the point covers at rest: x right, v down.
            Vertex(position: (point.x, point.y, z), texCoord: (point.x * 0.5 + 0.5, 0.5 - point.y * 0.5),
                   center: center, normal: normal)
        }

        // Sides: a quad per edge, facing out (to the right of a counter-clockwise edge).
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let outward = simd_normalize(SIMD2<Float>(b.y - a.y, a.x - b.x))
            let normal = (x: outward.x, y: outward.y, z: Float(0))
            let frontA = vertex(a, z: 0, normal: normal), frontB = vertex(b, z: 0, normal: normal)
            let backA = vertex(a, z: -depth, normal: normal), backB = vertex(b, z: -depth, normal: normal)
            vertices += [frontA, backA, frontB, frontB, backA, backB]
        }
        // Front: a fan around the centroid.
        let front = (x: Float(0), y: Float(0), z: Float(1))
        let middle = vertex(centroid, z: 0, normal: front)
        for index in points.indices {
            vertices += [middle, vertex(points[index], z: 0, normal: front),
                         vertex(points[(index + 1) % points.count], z: 0, normal: front)]
        }
    }
}

/// A small deterministic generator (SplitMix64), so the facets don't depend on the system's.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextUnit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
