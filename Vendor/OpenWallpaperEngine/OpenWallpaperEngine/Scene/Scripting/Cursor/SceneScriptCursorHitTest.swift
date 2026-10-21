import simd

/// WE's cursor hit tests (docs/scenescript-plan.md §4.8): the quad of an image or text layer and
/// the box of a model, against the cursor ray (`SceneScriptCursorRay`). Neither has an alpha test,
/// and neither checks the ray's parameter, so an object behind the ray's origin is hit too.
enum SceneScriptCursorHitTest {
    struct Result: Equatable {
        var isInside: Bool
        var localPosition: SIMD3<Float>
    }

    static func test(_ layer: SceneScriptCursorLayer, ray: SceneScriptCursorRay, offset: SIMD2<Float>) -> Result {
        switch layer.shape {
        case .quad:
            return quad(layer, ray: ray, offset: offset)
        case .model(let bounds):
            guard let bounds else { return Result(isInside: false, localPosition: .zero) }
            return box(bounds, world: layer.worldMatrix, ray: ray)
        }
    }

    /// The test of an orthographic scene, through the scene point `cursor`.
    static func test(_ layer: SceneScriptCursorLayer, cursor: SIMD2<Float>, offset: SIMD2<Float>) -> Result {
        test(layer, ray: .orthographic(through: cursor), offset: offset)
    }

    /// An image or text layer (wallpaper64.exe 0x14019dbb0, which calls the ray–parallelogram test
    /// 0x14019d5a0).
    ///
    /// The quad is the layer's `size` centred on its world translation plus the parallax offset,
    /// with the world matrix's x and y axes (so rotation, scale and parents apply): corners
    /// `centre ± 0.5·size.x·axisX ± 0.5·size.y·axisY`. The test is Möller–Trumbore's without the
    /// triangle's `u + v ≤ 1`: with `e1 = size.x·axisX` and `e2 = size.y·axisY`, the determinant
    /// `e1 · (direction × e2)` must exceed `FLT_EPSILON` in magnitude, or the quad is edge-on to the
    /// ray and never hit, with a zero local position. `u` runs from the left edge to the right, `v`
    /// from the bottom edge to the top; both must lie in 0…1, edges included. The local position is
    /// written even outside the quad: `(u·size.x, (1 − v)·size.y, 0)`, from the top-left corner with
    /// y down, which is what `CursorEvent.localPosition` reports ("0 to thisLayer.size"). For an
    /// orthographic ray, `(0, 0, −1)`, this is the 2D test of the quad's projection.
    private static func quad(_ layer: SceneScriptCursorLayer, ray: SceneScriptCursorRay, offset: SIMD2<Float>) -> Result {
        let matrix = layer.worldMatrix
        let axisX = SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z) * layer.size.x
        let axisY = SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z) * layer.size.y
        let centre = SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z) + SIMD3(offset, 0)
        let corner: SIMD3<Float> = centre - 0.5 * axisX - 0.5 * axisY
        let p = simd_cross(ray.direction, axisY)
        let determinant = simd_dot(axisX, p)
        guard abs(determinant) > Float.ulpOfOne else { return Result(isInside: false, localPosition: .zero) }
        let delta = ray.origin - corner
        let u = simd_dot(delta, p) / determinant
        let v = simd_dot(ray.direction, simd_cross(delta, axisX)) / determinant
        let inside = u >= 0 && u <= 1 && v >= 0 && v <= 1
        return Result(isInside: inside, localPosition: SIMD3(u * layer.size.x, (1 - v) * layer.size.y, 0))
    }

    /// A model (wallpaper64.exe 0x140185520): the ray into the model's space through the inverse of
    /// the object's matrix (vt+0x80; the direction not normalized), then the slab test of the box of
    /// its mesh bounds, `min…max` with half extents `h = (max − min) / 2`. WE subtracts `h` from the
    /// ray's origin in the space vt+0x80 gives, which starts at the box's `min`: WE 2.8.0.42 (capture
    /// 539, a unit cube around its origin at scale 0.01) hits the lower-left quarter of the cube's
    /// front face as well as the upper-right, at local (−21.5, −21.2, 50) and (30.8, 11.4, 50). A
    /// model without mesh boxes is `MDLBounds.unbounded` (±131072). A box with `max.x ≤ min.x` is
    /// never hit. The local position is where the ray enters, from the box's centre in model units:
    /// `o′ − c + t·d′`, with `c = (min + max) / 2` and `t` the entering parameter.
    static func box(_ bounds: MDLBounds, world: simd_float4x4, ray: SceneScriptCursorRay) -> Result {
        let miss = Result(isInside: false, localPosition: .zero)
        guard bounds.max.x > bounds.min.x else { return miss }
        let inverse = world.inverse
        let origin4: SIMD4<Float> = inverse * SIMD4<Float>(ray.origin, 1)
        let direction4: SIMD4<Float> = inverse * SIMD4<Float>(ray.direction, 0)
        let half: SIMD3<Float> = (bounds.max - bounds.min) * 0.5
        let centre: SIMD3<Float> = (bounds.min + bounds.max) * 0.5
        let start: SIMD3<Float> = SIMD3(origin4.x, origin4.y, origin4.z) - centre
        let direction = SIMD3<Float>(direction4.x, direction4.y, direction4.z)
        guard let enter = slab(origin: start, direction: direction, half: half) else { return miss }
        return Result(isInside: true, localPosition: start + enter * direction)
    }

    /// A named hit box under the ray: its name, and on a model the local position in its frame.
    struct NamedHit: Equatable {
        var name: String
        var localPosition: SIMD3<Float>?
    }

    /// The hit box of `layer` the ray meets (the object's vt+0x88; nil without one).
    ///
    /// Each box is tested in its own frame, `boneWorld · box.matrix`: the ray goes in through the
    /// frame's inverse, its direction normalized there, and meets the box `−halfExtents…halfExtents`
    /// (`slab`).
    /// - **Puppet** (0x1401fd690): the bones of its draw-depth order from the end (the topmost
    ///   limb first); the first box hit names it. No local position.
    /// - **Model** (0x140223810): every bone's box; the nearest entering parameter (each measured in
    ///   its own frame's units, below `FLT_MAX`) names it and gives the local position, the entry
    ///   point in that box's frame. A model without a pose (no animator) hangs its boxes from its
    ///   world matrix and names them by index (0x140224519).
    static func hitBox(_ layer: SceneScriptCursorLayer, ray: SceneScriptCursorRay) -> NamedHit? {
        guard let set = layer.hitBoxes, !set.boxes.isEmpty else { return nil }
        func enter(_ box: SceneScriptCursorShape.HitBox, frame: simd_float4x4) -> (t: Float, local: SIMD3<Float>)? {
            let inverse = frame.inverse
            let origin4: SIMD4<Float> = inverse * SIMD4<Float>(ray.origin, 1)
            let direction4: SIMD4<Float> = inverse * SIMD4<Float>(ray.direction, 0)
            let origin = SIMD3<Float>(origin4.x, origin4.y, origin4.z)
            let raw = SIMD3<Float>(direction4.x, direction4.y, direction4.z)
            let direction: SIMD3<Float> = raw * (1 / simd_length(raw))
            guard let t = slab(origin: origin, direction: direction, half: box.halfExtents) else { return nil }
            return (t, origin + t * direction)
        }
        if let order = set.order {
            for bone in order.reversed() where set.boxes.indices.contains(bone) && set.boneWorlds.indices.contains(bone) {
                let box = set.boxes[bone]
                if enter(box, frame: set.boneWorlds[bone] * box.matrix) != nil { return NamedHit(name: box.name) }
            }
            return nil
        }
        var best = Float.greatestFiniteMagnitude
        var found: NamedHit?
        let posed = !set.boneWorlds.isEmpty
        for (index, box) in set.boxes.enumerated() {
            let frame: simd_float4x4
            if posed {
                guard index < set.boneWorlds.count else { break }
                frame = set.boneWorlds[index] * box.matrix
            } else {
                frame = layer.worldMatrix * box.matrix
            }
            guard let hit = enter(box, frame: frame), hit.t < best else { continue }
            best = hit.t
            found = NamedHit(name: posed ? box.name : String(index), localPosition: hit.local)
        }
        return found
    }

    /// The slab test of the box `−half…half` (wallpaper64.exe 0x1401853c0, also inlined in
    /// 0x140185520 and 0x1401fd690): the entering parameter, or nil when the ray misses. It keeps
    /// SSE's `minss`/`maxss` and the compiler's `comiss`/`cmovbe` picks, so an axis the ray runs
    /// along (an infinite or NaN parameter) resolves as WE's does; an unordered final comparison is
    /// a miss.
    static func slab(origin: SIMD3<Float>, direction: SIMD3<Float>, half: SIMD3<Float>) -> Float? {
        let inverse = SIMD3<Float>(repeating: 1) / direction
        let high: SIMD3<Float> = (half - origin) * inverse
        let low: SIMD3<Float> = (-half - origin) * inverse
        // minss/maxss give the first operand when the comparison holds, else the second.
        func minss(_ a: Float, _ b: Float) -> Float { a < b ? a : b }
        func maxss(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
        let xMin = minss(high.x, low.x), xMax = maxss(high.x, low.x)
        // The y and z picks: `low` unless it compares above `high`, `high` unless `low` is above.
        let yMin = low.y > high.y ? high.y : low.y, zMin = low.z > high.z ? high.z : low.z
        let yMax = high.y > low.y ? high.y : low.y, zMax = high.z > low.z ? high.z : low.z
        let enter = maxss(zMin, maxss(yMin, xMin))
        let leave = minss(zMax, minss(yMax, xMax))
        return leave >= enter ? enter : nil
    }
}
