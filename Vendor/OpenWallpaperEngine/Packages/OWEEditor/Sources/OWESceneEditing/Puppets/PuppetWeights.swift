import Foundation
import simd

/// Automatic skin weights and the weight brush. Every result is at most four bones a vertex,
/// summing to 1 (`PuppetWeight.normalized`), what `a_BlendIndices`/`a_BlendWeights` hold.
public enum PuppetAutoWeights {
    public enum Method: String, CaseIterable, Codable, Sendable {
        /// Inverse distance to each bone's segment: quick, ignores the shape.
        case distance
        /// Heat diffusion over the mesh from each bone (Baran and Popović's bone heat): weights
        /// follow the shape, so a bone doesn't reach across a gap to a neighbouring part.
        case heat
    }

    /// Each bone as a segment in model space: from its head to its first child's head, or for a
    /// bone without children a stub along its x axis (half its parent's length, else 50 pixels).
    public static func segments(_ document: PuppetDocument) -> [(SIMD2<Float>, SIMD2<Float>)] {
        segments(document, worlds: document.bindWorlds)
    }

    /// The same for a pose's model-space matrices.
    public static func segments(_ document: PuppetDocument, worlds: [simd_float4x4]) -> [(SIMD2<Float>, SIMD2<Float>)] {
        guard worlds.count == document.bones.count else { return [] }
        var lengths = [Float](repeating: 0, count: document.bones.count)
        var result: [(SIMD2<Float>, SIMD2<Float>)] = []
        for index in document.bones.indices {
            let head = PuppetMath.origin(of: worlds[index])
            if let child = document.children(of: index).first {
                let tail = PuppetMath.origin(of: worlds[child])
                lengths[index] = simd_distance(head, tail)
                result.append((head, tail))
            } else {
                let parentLength = document.bones[index].parent.map { lengths[$0] } ?? 0
                let length = document.bones[index].length.flatMap { $0 > 0 ? $0 : nil } ?? (parentLength > 0 ? parentLength * 0.5 : 50)
                let axis = PuppetMath.transform(SIMD2(1, 0), worlds[index]) - head
                let direction = simd_length(axis) > 0 ? simd_normalize(axis) : SIMD2<Float>(1, 0)
                lengths[index] = length
                result.append((head, head + direction * length))
            }
        }
        return result
    }

    /// Weights for every vertex of the document.
    public static func compute(_ document: PuppetDocument, method: Method) -> [[PuppetWeight]] {
        guard !document.bones.isEmpty else { return Array(repeating: [], count: document.mesh.vertices.count) }
        switch method {
        case .distance: return distance(document)
        case .heat: return heat(document)
        }
    }

    static func distance(_ document: PuppetDocument) -> [[PuppetWeight]] {
        let bones = segments(document)
        return document.mesh.vertices.map { vertex in
            let entries = bones.enumerated().map { index, segment -> PuppetWeight in
                let d = PuppetMath.distance(vertex.position, segment: segment.0, segment.1)
                return PuppetWeight(bone: index, weight: 1 / pow(max(d, 0.5), 4))
            }
            return PuppetWeight.normalized(entries)
        }
    }

    // MARK: Heat

    static func heat(_ document: PuppetDocument) -> [[PuppetWeight]] {
        let mesh = document.mesh
        let n = mesh.vertices.count
        guard n > 0, !mesh.triangles.isEmpty else { return distance(document) }
        let bones = segments(document)
        let laplacian = cotangentLaplacian(mesh)
        // Each vertex's nearest bones (ties within 1 ‰ share) and the heat it takes from them.
        var nearest = [[Int]](repeating: [], count: n)
        var heatDiagonal = [Double](repeating: 0, count: n)
        for (index, vertex) in mesh.vertices.enumerated() {
            let distances = bones.map { PuppetMath.distance(vertex.position, segment: $0.0, $0.1) }
            let closest = distances.min() ?? 0
            nearest[index] = distances.indices.filter { distances[$0] <= closest * 1.001 + 1e-4 }
            let d = Double(max(closest, 0.5))
            // M·H: the vertex's area times 1/d² (dimensionless in the plane).
            heatDiagonal[index] = laplacian.mass[index] / (d * d)
        }
        var columns: [[Double]] = []
        for bone in bones.indices {
            var rhs = [Double](repeating: 0, count: n)
            var any = false
            for vertex in 0..<n where nearest[vertex].contains(bone) {
                rhs[vertex] = heatDiagonal[vertex] / Double(nearest[vertex].count)
                any = true
            }
            columns.append(any ? conjugateGradient(laplacian, diagonal: heatDiagonal, rhs: rhs) : [Double](repeating: 0, count: n))
        }
        return (0..<n).map { vertex in
            let entries = bones.indices.map { PuppetWeight(bone: $0, weight: Float(max(columns[$0][vertex], 0))) }
            let normalized = PuppetWeight.normalized(entries)
            // A vertex the heat didn't reach (a separate piece without a bone) takes its nearest bone.
            return normalized.isEmpty ? nearest[vertex].prefix(1).map { PuppetWeight(bone: $0, weight: 1) } : normalized
        }
    }

    /// The mesh's cotangent Laplacian (negative cotangents clamped to keep it an M-matrix) and
    /// each vertex's lumped area.
    struct Laplacian {
        var neighbours: [[(Int, Double)]]
        var diagonal: [Double]
        var mass: [Double]

        /// (L + D) · x.
        func apply(_ x: [Double], extra: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            for i in x.indices {
                var sum = (diagonal[i] + extra[i]) * x[i]
                for (j, w) in neighbours[i] { sum -= w * x[j] }
                y[i] = sum
            }
            return y
        }
    }

    static func cotangentLaplacian(_ mesh: PuppetMesh) -> Laplacian {
        let n = mesh.vertices.count
        var weights = [[Int: Double]](repeating: [:], count: n)
        var mass = [Double](repeating: 0, count: n)
        for t in mesh.triangles {
            let ids = [Int(t.x), Int(t.y), Int(t.z)]
            let p = ids.map { SIMD2<Double>(Double(mesh.vertices[$0].position.x), Double(mesh.vertices[$0].position.y)) }
            let area = abs((p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[2].x - p[0].x) * (p[1].y - p[0].y)) / 2
            for k in 0..<3 { mass[ids[k]] += area / 3 }
            for k in 0..<3 {
                // The angle at corner k faces the edge (k+1, k+2).
                let a = p[(k + 1) % 3] - p[k], b = p[(k + 2) % 3] - p[k]
                let cross = abs(a.x * b.y - a.y * b.x)
                let cot = cross > 1e-12 ? simd_dot(a, b) / cross : 0
                let w = max(cot, 1e-3) / 2
                let i = ids[(k + 1) % 3], j = ids[(k + 2) % 3]
                weights[i][j, default: 0] += w
                weights[j][i, default: 0] += w
            }
        }
        let neighbours = weights.map { $0.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 } }
        let diagonal = neighbours.map { $0.reduce(0) { $0 + $1.1 } }
        return Laplacian(neighbours: neighbours, diagonal: diagonal, mass: mass.map { max($0, 1e-9) })
    }

    /// Solves (L + diag(extra)) x = b by Jacobi-preconditioned conjugate gradients.
    static func conjugateGradient(_ laplacian: Laplacian, diagonal extra: [Double], rhs b: [Double],
                                  iterations: Int = 1000, tolerance: Double = 1e-10) -> [Double] {
        let n = b.count
        var x = [Double](repeating: 0, count: n)
        var r = b
        let preconditioner = (0..<n).map { 1 / max(laplacian.diagonal[$0] + extra[$0], 1e-12) }
        var z = zip(r, preconditioner).map { $0 * $1 }
        var p = z
        var rz = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
        let bNorm = max(b.reduce(0) { $0 + $1 * $1 }, 1e-30)
        for _ in 0..<iterations {
            let ap = laplacian.apply(p, extra: extra)
            let pap = zip(p, ap).reduce(0) { $0 + $1.0 * $1.1 }
            guard pap > 0 else { break }
            let alpha = rz / pap
            for i in 0..<n {
                x[i] += alpha * p[i]
                r[i] -= alpha * ap[i]
            }
            if r.reduce(0, { $0 + $1 * $1 }) / bNorm < tolerance { break }
            z = zip(r, preconditioner).map { $0 * $1 }
            let rzNext = zip(r, z).reduce(0) { $0 + $1.0 * $1.1 }
            let beta = rzNext / rz
            rz = rzNext
            for i in 0..<n { p[i] = z[i] + beta * p[i] }
        }
        return x
    }
}

/// The weight-paint brush: one dab changes one bone's weight on the vertices under it, falling
/// off to the brush's edge; the vertex's other bones make up the rest, so it always sums to 1.
public struct PuppetWeightBrush: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Codable, Sendable {
        /// Raises the bone's weight.
        case add
        /// Lowers it; what it loses goes to the vertex's other bones (else its parent).
        case subtract
        /// Moves every weight toward the neighbours' average.
        case smooth
        /// Sets the bone's weight to the strength.
        case replace
    }

    public var mode: Mode = .add
    /// Model-space pixels.
    public var radius: Float = 40
    /// 0…1: how much one dab changes (or, replacing, the weight it sets).
    public var strength: Float = 0.25

    public init(mode: Mode = .add, radius: Float = 40, strength: Float = 0.25) {
        self.mode = mode
        self.radius = radius
        self.strength = strength
    }

    /// The falloff at `distance` from the centre: 1 there, 0 at the edge (smoothstep).
    public func falloff(_ distance: Float) -> Float {
        guard radius > 0, distance < radius else { return 0 }
        let t = 1 - distance / radius
        return t * t * (3 - 2 * t)
    }

    /// One dab at `centre` for `bone`.
    public func apply(to document: inout PuppetDocument, bone: Int, at centre: SIMD2<Float>) {
        guard document.bones.indices.contains(bone) else { return }
        let adjacency = mode == .smooth ? document.mesh.adjacency : []
        let before = document.weights
        for (index, vertex) in document.mesh.vertices.enumerated() {
            let influence = falloff(simd_distance(vertex.position, centre)) * strength
            guard influence > 0, index < document.weights.count else { continue }
            switch mode {
            case .add:
                document.weights[index] = Self.setting(bone, to: PuppetWeight.weight(of: bone, in: before[index]) + influence,
                                                       in: before[index], document: document)
            case .subtract:
                document.weights[index] = Self.setting(bone, to: PuppetWeight.weight(of: bone, in: before[index]) - influence,
                                                       in: before[index], document: document)
            case .replace:
                let current = PuppetWeight.weight(of: bone, in: before[index])
                let target = current + (strength - current) * falloff(simd_distance(vertex.position, centre))
                document.weights[index] = Self.setting(bone, to: target, in: before[index], document: document)
            case .smooth:
                let neighbours = adjacency[index]
                guard !neighbours.isEmpty else { continue }
                var sums: [Int: Float] = [:]
                for neighbour in neighbours { for entry in before[neighbour] { sums[entry.bone, default: 0] += entry.weight } }
                var mixed: [Int: Float] = [:]
                for entry in before[index] { mixed[entry.bone, default: 0] += entry.weight * (1 - influence) }
                for (key, sum) in sums { mixed[key, default: 0] += sum / Float(neighbours.count) * influence }
                document.weights[index] = PuppetWeight.normalized(mixed.map { PuppetWeight(bone: $0.key, weight: $0.value) })
            }
        }
    }

    /// `entries` with `bone` at `value` (clamped to 0…1) and the others scaled to fill the rest.
    static func setting(_ bone: Int, to value: Float, in entries: [PuppetWeight], document: PuppetDocument) -> [PuppetWeight] {
        let value = min(max(value, 0), 1)
        let others = entries.filter { $0.bone != bone }
        let othersTotal = others.reduce(0) { $0 + $1.weight }
        var result: [PuppetWeight] = value > 0 ? [PuppetWeight(bone: bone, weight: value)] : []
        if othersTotal > 0 {
            result += others.map { PuppetWeight(bone: $0.bone, weight: $0.weight / othersTotal * (1 - value)) }
        } else if value < 1 {
            // Nothing else holds the vertex: the parent (else any other bone) takes the rest.
            let heir = document.bones[bone].parent ?? document.bones.indices.first { $0 != bone }
            if let heir { result.append(PuppetWeight(bone: heir, weight: 1 - value)) } else { return [PuppetWeight(bone: bone, weight: 1)] }
        }
        return PuppetWeight.normalized(result)
    }
}
