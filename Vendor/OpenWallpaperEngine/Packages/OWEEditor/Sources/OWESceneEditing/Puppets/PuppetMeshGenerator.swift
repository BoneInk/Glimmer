import Foundation
import simd

/// An image's alpha channel, row by row from the top: what the mesh is fitted to.
public struct PuppetAlphaMask: Sendable {
    public let width: Int
    public let height: Int
    /// `width · height` values, 0…255, top row first.
    public let alpha: [UInt8]

    public init(width: Int, height: Int, alpha: [UInt8]) {
        precondition(alpha.count == width * height, "one alpha value per pixel")
        self.width = width
        self.height = height
        self.alpha = alpha
    }

    public func value(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return alpha[y * width + x]
    }

    /// The mask shrunk by `factor` (each value the largest of its block), so nothing opaque is lost.
    func reduced(by factor: Int) -> PuppetAlphaMask {
        guard factor > 1 else { return self }
        let w = (width + factor - 1) / factor, h = (height + factor - 1) / factor
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y / factor) * w + x / factor
                out[index] = max(out[index], alpha[y * width + x])
            }
        }
        return PuppetAlphaMask(width: w, height: h, alpha: out)
    }
}

/// Fits a mesh to an image's alpha (WE's Puppet Warp "Generate mesh"): the outline of the
/// opaque pixels traced (marching squares), simplified and spaced, points filling the inside on
/// a staggered grid, a Delaunay triangulation of them all, and only the triangles inside the
/// shape kept. Positions are in the mesh's space (centred, y up) with texture coordinates where
/// the image lies.
public enum PuppetMeshGenerator {
    public struct Options: Hashable, Sendable {
        /// Pixels between points, inside and along the outline: the density (smaller is denser).
        public var spacing: Float
        /// Alpha at or below this is outside (0…255).
        public var threshold: UInt8
        /// How far (pixels) the outline is pushed out past the opaque pixels, so soft edges stay
        /// inside the mesh.
        public var padding: Float

        public init(spacing: Float = 40, threshold: UInt8 = 8, padding: Float = 2) {
            self.spacing = spacing
            self.threshold = threshold
            self.padding = padding
        }
    }

    /// The mesh for `mask`; empty when nothing is opaque.
    public static func generate(_ mask: PuppetAlphaMask, options: Options = Options()) -> PuppetMesh {
        let spacing = max(options.spacing, 2)
        // Work on a reduced mask: a cell a quarter of the spacing keeps the outline's detail.
        let factor = max(1, Int(spacing / 8))
        let small = mask.reduced(by: factor)
        let scale = Float(factor)
        let padding = Int((options.padding / scale).rounded(.up))
        let inside = dilate(binary(small, threshold: options.threshold), width: small.width, height: small.height,
                            radius: padding)
        let loops = traceOutlines(inside, width: small.width, height: small.height)
        guard !loops.isEmpty else { return PuppetMesh() }
        // Points in image pixels (y down).
        var points: [SIMD2<Float>] = []
        var outline: [SIMD2<Float>] = []
        for loop in loops {
            let pixels = loop.map { $0 * scale }
            let simplified = simplify(closed: pixels, tolerance: max(scale * 0.75, spacing * 0.08))
            guard simplified.count >= 3 else { continue }
            outline += resample(closed: simplified, spacing: spacing)
        }
        guard outline.count >= 3 else { return PuppetMesh() }
        points += outline
        // The inside on a staggered grid, away from the outline.
        let grid = SpatialHash(cell: spacing)
        for point in outline { grid.insert(point) }
        let rowHeight = spacing * 0.8660254
        var row = 0
        var y = rowHeight / 2
        while y < Float(mask.height) {
            var x = (row % 2 == 0 ? spacing / 2 : spacing)
            while x < Float(mask.width) {
                let point = SIMD2(x, y)
                if isInside(point, inside, small.width, small.height, scale),
                   grid.nearestDistance(to: point) > spacing * 0.6 {
                    points.append(point)
                }
                x += spacing
            }
            y += rowHeight
            row += 1
        }
        let triangulation = PuppetDelaunay.triangulate(points)
        // Keep the triangles whose inside is inside the shape (a few samples: concave notches
        // span triangles whose centre alone is inside).
        let width = small.width, height = small.height
        var kept: [(Int, Int, Int)] = []
        for t in triangulation where triangleIsInside(points[t.0], points[t.1], points[t.2], inside, width, height, scale) {
            kept.append(t)
        }
        // Drop unused points; to the mesh's space.
        var map = [Int: UInt32]()
        var vertices: [PuppetVertex] = []
        let size = SIMD2(Float(mask.width), Float(mask.height))
        func index(_ i: Int) -> UInt32 {
            if let existing = map[i] { return existing }
            let p = points[i]
            let position = SIMD2(p.x - size.x / 2, size.y / 2 - p.y)
            let uv = SIMD2(p.x / size.x, p.y / size.y)
            vertices.append(PuppetVertex(position: position, uv: uv))
            map[i] = UInt32(vertices.count - 1)
            return UInt32(vertices.count - 1)
        }
        var triangles: [SIMD3<UInt32>] = []
        for t in kept {
            let triangle = SIMD3(index(t.0), index(t.1), index(t.2))
            triangles.append(triangle.orientedCounterClockwise(vertices))
        }
        return PuppetMesh(vertices: vertices, triangles: triangles)
    }

    // MARK: Mask

    static func binary(_ mask: PuppetAlphaMask, threshold: UInt8) -> [Bool] {
        mask.alpha.map { $0 > threshold }
    }

    /// Grows the set by `radius` cells (a square neighbourhood, two separable passes).
    static func dilate(_ cells: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        guard radius > 0 else { return cells }
        var horizontal = cells
        for y in 0..<height {
            var lastOn = -Int.max / 2
            var line = [Bool](repeating: false, count: width)
            for x in 0..<width {
                if cells[y * width + x] { lastOn = x }
                line[x] = x - lastOn <= radius
            }
            lastOn = Int.max / 2
            for x in stride(from: width - 1, through: 0, by: -1) {
                if cells[y * width + x] { lastOn = x }
                if lastOn - x <= radius { line[x] = true }
            }
            for x in 0..<width { horizontal[y * width + x] = line[x] }
        }
        var out = horizontal
        for x in 0..<width {
            var lastOn = -Int.max / 2
            for y in 0..<height {
                if horizontal[y * width + x] { lastOn = y }
                out[y * width + x] = y - lastOn <= radius
            }
            lastOn = Int.max / 2
            for y in stride(from: height - 1, through: 0, by: -1) {
                if horizontal[y * width + x] { lastOn = y }
                if lastOn - y <= radius { out[y * width + x] = true }
            }
        }
        return out
    }

    /// Whether the pixel point (full-resolution pixels, y down) is in the reduced set.
    /// Whether a triangle's centre and three points between the centre and its edge midpoints
    /// all lie inside the shape (a concave notch can hold a triangle whose centre alone is inside).
    static func triangleIsInside(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ cells: [Bool],
                                 _ width: Int, _ height: Int, _ scale: Float) -> Bool {
        let third: Float = 1.0 / 3.0
        let half: Float = 0.5
        let centre: SIMD2<Float> = (a + b + c) * third
        let ab: SIMD2<Float> = (a + b) * half
        let bc: SIMD2<Float> = (b + c) * half
        let ca: SIMD2<Float> = (c + a) * half
        let samples: [SIMD2<Float>] = [centre, (centre + ab) * half, (centre + bc) * half, (centre + ca) * half]
        for sample in samples where !isInside(sample, cells, width, height, scale) { return false }
        return true
    }

    static func isInside(_ point: SIMD2<Float>, _ cells: [Bool], _ width: Int, _ height: Int, _ scale: Float) -> Bool {
        let x = Int((point.x / scale).rounded(.down)), y = Int((point.y / scale).rounded(.down))
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return cells[y * width + x]
    }

    // MARK: Outline

    /// The closed outlines of the set (marching squares over the cells' centres, the set padded
    /// with an empty border so every outline closes), in cell units.
    static func traceOutlines(_ cells: [Bool], width: Int, height: Int) -> [[SIMD2<Float>]] {
        func on(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && cells[y * width + x]
        }
        // Edge points: a horizontal edge (x, y)–(x+1, y) is 2·key, a vertical one 2·key + 1.
        func key(_ x: Int, _ y: Int, vertical: Bool) -> Int { (((y + 1) * (width + 2) + (x + 1)) << 1) | (vertical ? 1 : 0) }
        func point(_ key: Int) -> SIMD2<Float> {
            let vertical = key & 1 == 1
            let cell = key >> 1
            let x = cell % (width + 2) - 1, y = cell / (width + 2) - 1
            // Sample (x, y) sits at the cell centre (x + ½, y + ½).
            return vertical ? SIMD2(Float(x) + 0.5, Float(y) + 1) : SIMD2(Float(x) + 1, Float(y) + 0.5)
        }
        var neighbours: [Int: [Int]] = [:]
        func link(_ a: Int, _ b: Int) {
            neighbours[a, default: []].append(b)
            neighbours[b, default: []].append(a)
        }
        for y in -1..<height {
            for x in -1..<width {
                let tl = on(x, y), tr = on(x + 1, y), br = on(x + 1, y + 1), bl = on(x, y + 1)
                let top = key(x, y, vertical: false), bottom = key(x, y + 1, vertical: false)
                let left = key(x, y, vertical: true), right = key(x + 1, y, vertical: true)
                var crossed: [Int] = []
                if tl != tr { crossed.append(top) }
                if tr != br { crossed.append(right) }
                if bl != br { crossed.append(bottom) }
                if tl != bl { crossed.append(left) }
                if crossed.count == 2 {
                    link(crossed[0], crossed[1])
                } else if crossed.count == 4 {
                    // A saddle: cut around each inside corner, so diagonal neighbours stay apart.
                    if tl { link(top, left); link(bottom, right) } else { link(top, right); link(bottom, left) }
                }
            }
        }
        var visited = Set<Int>()
        var loops: [[SIMD2<Float>]] = []
        for start in neighbours.keys.sorted() where !visited.contains(start) {
            var loop: [SIMD2<Float>] = []
            var previous = -1
            var current = start
            while !visited.contains(current) {
                visited.insert(current)
                loop.append(point(current))
                guard let next = neighbours[current]?.first(where: { $0 != previous && !visited.contains($0) })
                        ?? neighbours[current]?.first(where: { $0 != previous }) else { break }
                previous = current
                current = next
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    /// Douglas–Peucker on a closed polyline.
    static func simplify(closed points: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard points.count > 3 else { return points }
        // Split at the point farthest from the first, simplify both halves.
        let far = points.indices.max { simd_distance_squared(points[$0], points[0]) < simd_distance_squared(points[$1], points[0]) }!
        let first = simplify(open: Array(points[0...far]), tolerance: tolerance)
        let second = simplify(open: Array(points[far...]) + [points[0]], tolerance: tolerance)
        return Array(first.dropLast()) + Array(second.dropLast())
    }

    static func simplify(open points: [SIMD2<Float>], tolerance: Float) -> [SIMD2<Float>] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (start, end) = stack.popLast() {
            guard end > start + 1 else { continue }
            var farthest = start, distance: Float = 0
            for index in (start + 1)..<end {
                let d = PuppetMath.distance(points[index], segment: points[start], points[end])
                if d > distance { distance = d; farthest = index }
            }
            if distance > tolerance {
                keep[farthest] = true
                stack.append((start, farthest))
                stack.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// The closed polyline with points no farther apart than `spacing`.
    static func resample(closed points: [SIMD2<Float>], spacing: Float) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            out.append(a)
            let length = simd_distance(a, b)
            let pieces = Int((length / spacing).rounded(.up))
            if pieces > 1 {
                for step in 1..<pieces { out.append(a + (b - a) * (Float(step) / Float(pieces))) }
            }
        }
        return out
    }

    /// Points in square cells, for the distance to the nearest.
    final class SpatialHash {
        let cell: Float
        var buckets: [SIMD2<Int>: [SIMD2<Float>]] = [:]

        init(cell: Float) { self.cell = cell }

        func key(_ p: SIMD2<Float>) -> SIMD2<Int> { SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down))) }

        func insert(_ p: SIMD2<Float>) { buckets[key(p), default: []].append(p) }

        /// The distance to the nearest point within a cell or two; infinity beyond.
        func nearestDistance(to p: SIMD2<Float>) -> Float {
            let k = key(p)
            var best = Float.infinity
            for dy in -2...2 {
                for dx in -2...2 {
                    for q in buckets[k &+ SIMD2(dx, dy)] ?? [] { best = min(best, simd_distance(p, q)) }
                }
            }
            return best
        }
    }
}

/// Delaunay triangulation (Bowyer–Watson) of points in the plane.
public enum PuppetDelaunay {
    /// Triangles as index triples into `points`; duplicate points are skipped.
    public static func triangulate(_ points: [SIMD2<Float>]) -> [(Int, Int, Int)] {
        guard points.count >= 3 else { return [] }
        var low = points[0], high = points[0]
        for p in points {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        let size = max(high.x - low.x, high.y - low.y, 1)
        let mid = (low + high) / 2
        // Work in doubles: circumcircle tests on pixel coordinates need the precision.
        var all = points.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let n = points.count
        let m = SIMD2<Double>(Double(mid.x), Double(mid.y)), s = Double(size)
        all += [m + SIMD2(-20 * s, -20 * s), m + SIMD2(20 * s, -20 * s), m + SIMD2(0, 20 * s)]

        struct Triangle {
            var a: Int, b: Int, c: Int
            var centre: SIMD2<Double>
            var radius2: Double
        }
        func make(_ a: Int, _ b: Int, _ c: Int) -> Triangle? {
            let pa = all[a], pb = all[b], pc = all[c]
            let d = 2 * (pa.x * (pb.y - pc.y) + pb.x * (pc.y - pa.y) + pc.x * (pa.y - pb.y))
            guard abs(d) > 1e-12 else { return nil }
            let a2 = simd_length_squared(pa), b2 = simd_length_squared(pb), c2 = simd_length_squared(pc)
            let centre = SIMD2((a2 * (pb.y - pc.y) + b2 * (pc.y - pa.y) + c2 * (pa.y - pb.y)) / d,
                               (a2 * (pc.x - pb.x) + b2 * (pa.x - pc.x) + c2 * (pb.x - pa.x)) / d)
            return Triangle(a: a, b: b, c: c, centre: centre, radius2: simd_length_squared(pa - centre))
        }
        var triangles = [make(n, n + 1, n + 2)!]
        var seen = Set<SIMD2<Double>>()
        for index in 0..<n {
            let p = all[index]
            guard seen.insert(p).inserted else { continue }
            var bad: [Int] = []
            for (t, triangle) in triangles.enumerated() where simd_length_squared(p - triangle.centre) < triangle.radius2 * (1 + 1e-12) {
                bad.append(t)
            }
            // The cavity's boundary: edges of exactly one bad triangle.
            var edges: [SIMD2<Int>: Int] = [:]
            var order: [SIMD2<Int>] = []
            for t in bad {
                let tri = triangles[t]
                for (u, v) in [(tri.a, tri.b), (tri.b, tri.c), (tri.c, tri.a)] {
                    let key = SIMD2(min(u, v), max(u, v))
                    if edges[key] == nil { order.append(key) }
                    edges[key, default: 0] += 1
                }
            }
            for t in bad.sorted(by: >) { triangles.swapAt(t, triangles.count - 1); triangles.removeLast() }
            for edge in order where edges[edge] == 1 {
                if let triangle = make(edge.x, edge.y, index) { triangles.append(triangle) }
            }
        }
        return triangles.compactMap { t in
            t.a < n && t.b < n && t.c < n ? (t.a, t.b, t.c) : nil
        }
    }
}
