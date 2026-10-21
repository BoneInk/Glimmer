import simd

/// A collision operator (`collisionplane`, `collisionsphere`, `collisionquad`, `collisionbounds`,
/// `collisionmodel`), as authored in the emitter's space. Only a particle's centre collides, as in
/// WE.
struct ParticleCollision: Equatable {
    enum Shape: Equatable {
        /// Particles stay where `dot(normal, p) >= distance`.
        case plane(normal: SIMD3<Float>, distance: Float)
        /// A solid ball.
        case sphere(origin: SIMD3<Float>, radius: Float)
        /// A one-sided rectangle, hit from the side `normal` faces.
        case quad(origin: SIMD3<Float>, normal: SIMD3<Float>, forward: SIMD3<Float>, size: SIMD2<Float>)
        /// The scene's rectangle, `size` wide.
        case bounds(size: SIMD2<Float>)
        /// The capsules of the object the system's `collisionmodel` dependency with this index links
        /// (`ParticleCapsule`, docs/models-plan.md §2.12), in 3D.
        case model(index: Int)
    }

    /// `collisionbehavior`: bounce unless "slide", "stop" or "delete".
    enum Behavior: UInt32 {
        case bounce = 0, slide, stop, delete

        init(_ name: String?) {
            switch name?.lowercased() {
            case "slide": self = .slide
            case "stop": self = .stop
            case "delete": self = .delete
            default: self = .bounce
            }
        }
    }

    let shape: Shape
    let behavior: Behavior
    /// `bouncefactor` (default 0.5).
    let bounceFactor: Float
    /// Flag bit 0: the shape sits on this control point (its `origin` or `distance` ignored).
    let controlPoint: Int?
    /// Flag bit 1: a hit stops the particle's rotation.
    let stopsRotation: Bool

    /// The operator `element`, nil for one that isn't a collision WE resolves at runtime
    /// (`collisionbox` does nothing). Defaults (`wallpaper64.exe` 0x1401c00a0 and the shapes'
    /// fillers 0x1401c0540 / 0x1401c0740 / 0x1401c0870): plane "0 1 0" at −150 (2D) / 0, sphere at
    /// "0 −200 0" / 0 of radius 50 / 1, quad at "0 −150 0" / 0 of size "200 200" / "1 1", bounce
    /// factor 0.5, behaviour bounce. `collisionmodel` (0x1401cfd98) reads only `collisionbehavior`
    /// and `bouncefactor` (0x1401c03f0); `modelIndex` is its ordinal among the system's
    /// `collisionmodel` operators, which its `dependencies` link names (0x1401d91b0).
    init?(_ element: WEParticleOperator, sceneSize: SIMD2<Float>, defaults: ParticleDefaults = ParticleDefaults(pixelUnits: true),
          modelIndex: Int = 0) {
        func vector(_ value: WEFlexValue?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            guard let value else { return fallback }
            let v = value.vectorValue
            return SIMD3(Float(v.0), Float(v.1), Float(v.2))
        }
        switch element.name {
        case "collisionplane":
            shape = .plane(normal: vector(element.plane, SIMD3(0, 1, 0)), distance: Float(element.distance ?? defaults.pick(-150, 0)))
        case "collisionsphere":
            shape = .sphere(origin: vector(element.origin, defaults.pick(SIMD3(0, -200, 0), .zero)),
                            radius: Float(element.radius ?? defaults.pick(50, 1)))
        case "collisionquad":
            let size = element.size?.vectorValue ?? defaults.pick((200, 200, 0), (1, 1, 0))
            shape = .quad(origin: vector(element.origin, defaults.pick(SIMD3(0, -150, 0), .zero)), normal: vector(element.plane, SIMD3(0, 1, 0)),
                          forward: vector(element.forward, SIMD3(0, 0, 1)), size: SIMD2(Float(size.0), Float(size.1)))
        case "collisionbounds":
            shape = .bounds(size: sceneSize)
        case "collisionmodel":
            shape = .model(index: modelIndex)
        default:
            return nil
        }
        behavior = Behavior(element.collisionbehavior)
        bounceFactor = Float(element.bouncefactor ?? 0.5)
        if case .model = shape {
            controlPoint = nil
            stopsRotation = false
            return
        }
        let flags = element.flags ?? 0
        controlPoint = (flags & 1) != 0 ? min(max(element.controlpoint ?? 0, 0), 7) : nil
        stopsRotation = (flags & 2) != 0
    }

    init(shape: Shape, behavior: Behavior = .bounce, bounceFactor: Float = 0.5, controlPoint: Int? = nil,
         stopsRotation: Bool = false) {
        self.shape = shape
        self.behavior = behavior
        self.bounceFactor = bounceFactor
        self.controlPoint = controlPoint
        self.stopsRotation = stopsRotation
    }

    /// The objects a particle object's `collisionmodel` dependencies link, by their `index` (WE
    /// parses them at 0x14022b1f3 and binds them at 0x14022cfa0). The operator collides only
    /// with a model or a puppet image; an index nothing names collides with nothing.
    static func linkedModels(_ dependencies: [WEObjectDependency]) -> [Int: String] {
        var models: [Int: String] = [:]
        for case let .link(id, type, index) in dependencies where type?.lowercased() == "collisionmodel" {
            models[max(index ?? 0, 0)] = String(id)
        }
        return models
    }

    /// The `collisionmodel` dependency index, nil for the other shapes.
    var modelIndex: Int? {
        if case .model(let index) = shape { return index }
        return nil
    }

    /// The response every placement of this operator carries: −(1 + bounce factor), the
    /// behaviour and whether a hit stops the rotation.
    private var response: SIMD4<Float> {
        SIMD4(-(1 + bounceFactor), Float(behavior.rawValue), stopsRotation ? 1 : 0, 0)
    }

    /// A `collisionmodel`'s capsules as placements (`ParticleCollisionPlacement.Kind.capsule`), in
    /// the space the particles are drawn from (the scene's plane and depth). They stay where
    /// their model is, so an instance of an instanced system doesn't carry them.
    func placed(capsules: [ParticleCapsule]) -> [ParticleCollisionPlacement] {
        capsules.map { capsule in
            ParticleCollisionPlacement(kind: .capsule, shape: SIMD4(capsule.start, capsule.length),
                                       axis: SIMD4(capsule.direction, capsule.radius), extra: SIMD4(0, 0, 1, 0),
                                       response: response)
        }
    }

    /// The shape in scene space this frame. `controlPoint` gives a control point's position.
    func placed(in space: SceneParticleEmitterSpace, controlPoint position: (Int) -> SIMD2<Float>) -> [ParticleCollisionPlacement] {
        let scale = sqrt(abs(simd_determinant(space.world.linear)))
        let response = self.response
        func direction(_ v: SIMD3<Float>) -> SIMD2<Float>? {
            let turned = space.rotation * SIMD2(v.x, v.y)
            return simd_length(turned) > 1e-6 ? simd_normalize(turned) : nil
        }
        let anchor = controlPoint.map(position)
        switch shape {
        case .plane(let normal, let distance):
            guard let n = direction(normal) else { return [] }
            let d = anchor.map { simd_dot(n, $0) } ?? distance * scale + simd_dot(n, space.origin)
            return [ParticleCollisionPlacement(kind: .plane, shape: SIMD4(n.x, n.y, d, 0), response: response)]
        case .sphere(let origin, let radius):
            let center = anchor ?? space.world.apply(SIMD2(origin.x, origin.y))
            return [ParticleCollisionPlacement(kind: .sphere, shape: SIMD4(center.x, center.y, radius * scale, 0),
                                               response: response)]
        case .quad(let origin, let normal, let forward, let size):
            // WE's axes: right = normal × forward spans size.x, normal × … size.y (along z in 2D).
            let right3 = simd_cross(normal, forward)
            guard let n = direction(normal), let right = direction(right3) else { return [] }
            let up3 = simd_cross(simd_normalize(right3), simd_normalize(normal))
            let center = anchor ?? space.world.apply(SIMD2(origin.x, origin.y))
            let halfUp = simd_length(SIMD2(up3.x, up3.y)) > 1e-6 ? size.y / 2 * scale : .infinity
            let up = direction(up3) ?? .zero
            return [ParticleCollisionPlacement(kind: .quad, shape: SIMD4(center.x, center.y, n.x, n.y),
                                               axis: SIMD4(right.x, right.y, size.x / 2 * scale, halfUp),
                                               extra: SIMD4(up.x, up.y, 0, 0), response: response)]
        case .bounds(let size):
            // Keeps particles inside the scene.
            let planes: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, -size.x), SIMD3(0, -1, -size.y)]
            return planes.map {
                ParticleCollisionPlacement(kind: .plane, shape: SIMD4($0.x, $0.y, $0.z, 0),
                                           extra: SIMD4(0, 0, 1, 0), response: response)
            }
        case .model:
            // Placed from the linked object's capsules (`placed(capsules:)`).
            return []
        }
    }
}

/// A collision shape in scene space for one step (`ParticleCollision.placed`); the GPU reads the
/// same layout (`ParticleShared.h`).
struct ParticleCollisionPlacement: Equatable {
    enum Kind: UInt32 { case plane = 0, sphere, quad, capsule }

    /// Plane: normal xy, distance. Sphere: centre xy, radius. Quad: centre xy, normal xy.
    /// Capsule: start xyz (depth the particles' z), segment length.
    var shape: SIMD4<Float>
    /// Quad: right axis xy, half size along it, half size along `extra`. Capsule: unit direction
    /// xyz, radius.
    var axis = SIMD4<Float>.zero
    /// Quad: second axis xy. z: 1 when the shape is fixed in the scene (bounds), so an instance
    /// of an instanced system doesn't carry it (`moved(by:)`).
    var extra = SIMD4<Float>.zero
    /// Bounce coefficient −(1 + bouncefactor), behaviour, stops rotation, kind.
    var response: SIMD4<Float>

    init(kind: Kind, shape: SIMD4<Float>, axis: SIMD4<Float> = .zero, extra: SIMD4<Float> = .zero,
         response: SIMD4<Float>) {
        self.shape = shape
        self.axis = axis
        self.extra = extra
        self.response = SIMD4(response.x, response.y, response.z, Float(kind.rawValue))
    }

    var kind: Kind { Kind(rawValue: UInt32(response.w)) ?? .plane }

    /// The shape carried by `translation` (an instance's position).
    func moved(by translation: SIMD2<Float>) -> ParticleCollisionPlacement {
        guard extra.z < 0.5 else { return self }
        var moved = self
        switch kind {
        case .plane: moved.shape.z += simd_dot(SIMD2(shape.x, shape.y), translation)
        case .sphere, .quad, .capsule:
            moved.shape.x += translation.x
            moved.shape.y += translation.y
        }
        return moved
    }
}
