import simd

/// The bones a `layerimage` emitter's points follow on a Puppet Warp layer, as `wallpaper64.exe`
/// gives them (0x1401d6d30, after every sampling of the layer's points):
/// - Each bone's rest pose in the rig's space (its rest matrices chained through its parents, the
///   `.mdl`'s rest block when it has one; `SceneSkeleton.restWorld`) places the bone's hit box
///   (`MDLSkeleton.boneVectors`: half extents and the box's frame in the bone's space). The box is
///   the parallelogram through its corners (−w, h), (w, h) and (−w, −h).
/// - Bone by bone, a point inside a box takes that bone; one inside a second box too is marked.
///   A point inside none takes the bone whose box it lies least far outside of, by the largest of
///   its projections past the box's edges (WE treats a distance of 0 as none yet).
/// - A marked point (inside two boxes or more) then takes the bone of the nearest unmarked point,
///   the first of equally near ones, or none without one.
/// - Without hit boxes no point has a bone: the points stay where the layer is (WE reads past its
///   bone table then).
///
/// A spawn then follows its point's bone this frame: the bone's model matrix times the inverse of
/// its rest one (0x1401d4360), in the layer's space (`ParticleFrameInputs.placeImages`).
enum ParticleEmitterImageBones {
    /// A point's bone when it has none (WE's 0xff).
    static let none: Int32 = -1

    /// What the assignment reads from a rig: each bone's hit box and rest pose in the rig's space.
    struct Rig {
        var boxes: [MDLSkeleton.BoneVector]
        var restWorld: [simd_float4x4]

        init(boxes: [MDLSkeleton.BoneVector], restWorld: [simd_float4x4]) {
            self.boxes = boxes
            self.restWorld = restWorld
        }

        /// A Puppet Warp layer's rig; nil without one.
        init?(_ puppet: ScenePuppetPlan?) {
            guard let puppet else { return nil }
            self.init(boxes: puppet.skeleton.boneVectors ?? [], restWorld: SceneSkeleton(puppet.skeleton).restWorld)
        }
    }

    /// Writes each point's bone into its `w` (`none` without one), as WE assigns them.
    static func assign(_ points: inout [SIMD4<Int32>], rig: Rig) {
        let boxCount = min(rig.boxes.count, rig.restWorld.count)
        for index in points.indices { points[index].w = none }
        guard boxCount > 0, !points.isEmpty else { return }
        let count = points.count
        var inside = [Bool](repeating: false, count: count)
        var overlapping = [Bool](repeating: false, count: count)
        var outside = [Float](repeating: 0, count: count)
        for bone in 0..<boxCount {
            let box = rig.boxes[bone]
            let frame = rig.restWorld[bone] * box.matrix
            func corner(_ x: Float, _ y: Float) -> SIMD2<Float> {
                let placed: SIMD4<Float> = frame * SIMD4<Float>(x, y, 0, 1)
                return SIMD2(placed.x, placed.y)
            }
            let w = box.vector.x, h = box.vector.y
            let start = corner(-w, h), across = corner(w, h), down = corner(-w, -h)
            let edge = start - across, side = down - start
            let edgeLength: Float = simd_length_squared(edge), sideLength: Float = simd_length_squared(side)
            let marker = Int32(bone)
            for index in 0..<count {
                let point = SIMD2<Float>(Float(points[index].x), Float(points[index].y))
                let along: Float = simd_dot(point - across, edge)
                let beside: Float = simd_dot(point - start, side)
                if along >= 0, along <= edgeLength, beside >= 0, beside <= sideLength {
                    if points[index].w != none, inside[index] { overlapping[index] = true }
                    points[index].w = marker
                    inside[index] = true
                    continue
                }
                guard !inside[index] else { continue }
                var distance: Float = along < 0 ? -along : 0
                if along > edgeLength { distance = max(distance, along - edgeLength) }
                if beside < 0 { distance = max(distance, -beside) }
                if beside > sideLength { distance = max(distance, beside - sideLength) }
                if outside[index] == 0 || outside[index] > distance {
                    outside[index] = distance
                    points[index].w = marker
                }
            }
        }
        resolveOverlaps(&points, overlapping: overlapping)
    }

    /// Each marked point takes the bone of the nearest unmarked one (squared distance, the first
    /// of equally near ones in point order), or none without one (0x1401d74cc…0x1401d75d3). The
    /// points sit on the reduced image's grid, so the search walks grid cells outward from the
    /// point and stops once no unvisited cell can hold a nearer one.
    private static func resolveOverlaps(_ points: inout [SIMD4<Int32>], overlapping: [Bool]) {
        guard overlapping.contains(true) else { return }
        var low = SIMD2<Int32>(repeating: .max), high = SIMD2<Int32>(repeating: .min)
        var unmarked = 0
        for (index, point) in points.enumerated() where !overlapping[index] {
            low = simd_min(low, SIMD2(point.x, point.y))
            high = simd_max(high, SIMD2(point.x, point.y))
            unmarked += 1
        }
        guard unmarked > 0 else {
            for index in points.indices where overlapping[index] { points[index].w = none }
            return
        }
        // About one point a cell: the grid's pitch from the points' spread.
        let span = SIMD2<Float>(Float(high.x - low.x) + 1, Float(high.y - low.y) + 1)
        let cell = max(1, (span.x * span.y / Float(unmarked)).squareRoot())
        let columns = Int(span.x / cell) + 1, rows = Int(span.y / cell) + 1
        func cellOf(_ point: SIMD4<Int32>) -> SIMD2<Int> {
            SIMD2(min(max(Int(Float(point.x - low.x) / cell), 0), columns - 1),
                  min(max(Int(Float(point.y - low.y) / cell), 0), rows - 1))
        }
        // Unmarked points by cell, in point order within each.
        var starts = [Int](repeating: 0, count: columns * rows + 1)
        for (index, point) in points.enumerated() where !overlapping[index] {
            let c = cellOf(point)
            starts[c.y * columns + c.x + 1] += 1
        }
        for index in 1..<starts.count { starts[index] += starts[index - 1] }
        var fill = starts
        var members = [Int](repeating: 0, count: unmarked)
        for (index, point) in points.enumerated() where !overlapping[index] {
            let c = cellOf(point)
            members[fill[c.y * columns + c.x]] = index
            fill[c.y * columns + c.x] += 1
        }
        let reach = max(columns, rows)
        var assigned: [(Int, Int32)] = []
        for (index, point) in points.enumerated() where overlapping[index] {
            let origin = cellOf(point)
            let position = SIMD2<Float>(Float(point.x), Float(point.y))
            var best: (distance: Float, index: Int)?
            for ring in 0...reach {
                // Every point of ring `ring` or beyond is at least (ring − 1) cells away.
                if let found = best, ring > 0 {
                    let bound = Float(ring - 1) * cell
                    if found.distance < bound * bound { break }
                }
                for y in (origin.y - ring)...(origin.y + ring) where y >= 0 && y < rows {
                    let edgeRow = y == origin.y - ring || y == origin.y + ring
                    let step = edgeRow ? 1 : max(2 * ring, 1)
                    var x = origin.x - ring
                    while x <= origin.x + ring {
                        if x >= 0, x < columns {
                            let slot = y * columns + x
                            for member in members[starts[slot]..<starts[slot + 1]] {
                                let other = points[member]
                                let offset = SIMD2<Float>(Float(other.x), Float(other.y)) - position
                                let distance: Float = simd_length_squared(offset)
                                if best.map({ distance < $0.distance || (distance == $0.distance && member < $0.index) }) ?? true {
                                    best = (distance, member)
                                }
                            }
                        }
                        x += step
                    }
                }
            }
            assigned.append((index, best.map { points[$0.index].w } ?? none))
        }
        for (index, bone) in assigned { points[index].w = bone }
    }

    /// Each bone's motion since its rest pose this frame, in the rig's space: its model matrix
    /// times the inverse of its rest one (0x1401d4360), flattened to the image's plane.
    static func motion(worlds: [simd_float4x4], inverseRest: [simd_float4x4]) -> [SceneAffineTransform] {
        zip(worlds, inverseRest).map { world, inverse in flat(world * inverse) }
    }

    /// A 4 × 4 matrix's action on the plane: its x and y columns and translation without z.
    static func flat(_ matrix: simd_float4x4) -> SceneAffineTransform {
        SceneAffineTransform(linear: simd_float2x2(SIMD2(matrix.columns.0.x, matrix.columns.0.y),
                                                   SIMD2(matrix.columns.1.x, matrix.columns.1.y)),
                             translation: SIMD2(matrix.columns.3.x, matrix.columns.3.y))
    }
}

/// A Puppet Warp layer's bones as a `layerimage` emitter on it reads them each frame
/// (`ParticleFrameInputs.advance`'s `layerBones`).
struct ParticleLayerBones: Equatable {
    /// Each bone's motion since its rest pose this frame, in the layer's space
    /// (`ParticleEmitterImageBones.motion`).
    var motion: [SceneAffineTransform]
    /// `motion` last frame, which goes through the layer's world then: WE keeps last frame's bones
    /// in the scene (puppet+0x348, swapped with this frame's each update, 0x1402003e2); nil on the
    /// rig's first frame, when it has none and takes the identity for them (0x1401d4400).
    var previous: [SceneAffineTransform]?
    /// The inverse of each bone's rest pose, which that identity is multiplied by.
    var inverseRest: [SceneAffineTransform]
}

/// One bone of a `layerimage` emitter's step: where its points spawn this step and, for an emitter
/// inheriting the layer's motion, where they were last frame, both in the system's space.
struct ParticleImageBone: Equatable {
    var current: SceneAffineTransform
    var previous: SceneAffineTransform
}
