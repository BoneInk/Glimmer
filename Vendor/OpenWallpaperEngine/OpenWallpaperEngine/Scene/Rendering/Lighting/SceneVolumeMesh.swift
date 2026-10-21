import simd

/// The meshes WE draws a light's volume with (`wallpaper64.exe` 0x140196ce0, docs/lighting-plan.md
/// §2.8): built once per light, then placed each frame by `g_AltViewProjectionMatrix`.
///
/// - **Box** (a spot with a cookie or a shadow, 0x1401970a4): the 8 corners of the light's clip
///   volume, x and y ±1, z at the near and far depths, as 12 triangles. Placed by the inverse of
///   the light's projection, it is the light's frustum.
/// - **Cone** (any other spot, 0x140197258): 32 segments of the circle inscribed in that clip
///   square, at the near and far depths, with a fan cap at each; its centres are at (0.5, 0.5), as
///   WE writes them. Placed like the box, it is the spot's cone.
/// - **Sphere** (a point light, 0x14025c660 with radius 1): the poles and 23 rings of 25 vertices
///   (latitude steps of π/24, longitude steps of π/12). Placed by the light's radius and position.
///
/// WE's triangles are kept, but each is wound outward (counter-clockwise seen from outside), so the
/// renderer can pick the near or the far faces of the convex volume by culling
/// (`SceneVolumetricsPipelines`). The sphere's own index order wasn't traced [?]; it is a plain
/// band triangulation of WE's vertices.
struct SceneVolumeMesh: Equatable {
    enum Shape: Equatable {
        case box, cone, sphere
    }

    let positions: [SIMD3<Float>]
    let indices: [UInt16]

    /// The clip depths of the near and far planes: 1 and 0, as WE writes them with reversed depth
    /// (0x14025c5f0 and 0x14025c5d0 test the context's reversed-depth flag, 0x1000 of ctx+0x118;
    /// the light and scene projections are reversed, so the flag is set [I]).
    static let nearDepth: Float = 1
    static let farDepth: Float = 0

    static func make(_ shape: Shape) -> SceneVolumeMesh {
        switch shape {
        case .box: return box
        case .cone: return cone
        case .sphere: return sphere
        }
    }

    static let box: SceneVolumeMesh = {
        // Far corners first, then near ones (0x1401970b7…0x140197126).
        var positions: [SIMD3<Float>] = []
        for depth in [farDepth, nearDepth] {
            positions += [SIMD3(-1, -1, depth), SIMD3(1, -1, depth), SIMD3(1, 1, depth), SIMD3(-1, 1, depth)]
        }
        // The index list WE stores at 0x14019716e…0x14019722f.
        let indices: [UInt16] = [1, 0, 2, 2, 0, 3, 4, 5, 6, 4, 6, 7, 3, 0, 4, 3, 4, 7,
                                 1, 2, 5, 5, 2, 6, 2, 3, 6, 6, 3, 7, 0, 1, 5, 0, 5, 4]
        return outward(positions: positions, indices: indices)
    }()

    static let coneSegments = 32

    static let cone: SceneVolumeMesh = {
        // The caps' centres: far (index 0), then near (index 1).
        var positions: [SIMD3<Float>] = [SIMD3(0.5, 0.5, farDepth), SIMD3(0.5, 0.5, nearDepth)]
        var indices: [UInt16] = []
        let step = 2 * Float.pi / Float(coneSegments)
        for segment in 0..<coneSegments {
            let a = Float(segment) * step, b = a + step
            let base = UInt16(positions.count)
            // (sin, −cos) of both edges, at the near depth then the far one (0x1401972c2…0x1401973b3).
            positions += [SIMD3(sin(a), -cos(a), nearDepth), SIMD3(sin(b), -cos(b), nearDepth),
                          SIMD3(sin(a), -cos(a), farDepth), SIMD3(sin(b), -cos(b), farDepth)]
            // The side quad, then a triangle of each cap (0x1401973b8…0x1401974d2).
            indices += [base + 2, base, base + 1, base + 2, base + 1, base + 3,
                        1, base + 1, base, 0, base + 2, base + 3]
        }
        return outward(positions: positions, indices: indices)
    }()

    static let sphere: SceneVolumeMesh = {
        var positions: [SIMD3<Float>] = [SIMD3(0, 1, 0), SIMD3(0, -1, 0)]
        let rings = 23, columns = 25
        for ring in 1...rings {
            let latitude = Float(ring) * Float.pi / 24
            for column in 0..<columns {
                let longitude = Float(column) * Float.pi / 12
                positions.append(SIMD3(cos(longitude) * sin(latitude), cos(latitude), sin(longitude) * sin(latitude)))
            }
        }
        func vertex(_ ring: Int, _ column: Int) -> UInt16 { UInt16(2 + (ring - 1) * columns + column) }
        var indices: [UInt16] = []
        for column in 0..<(columns - 1) {
            indices += [0, vertex(1, column), vertex(1, column + 1)]
            indices += [1, vertex(rings, column + 1), vertex(rings, column)]
        }
        for ring in 1..<rings {
            for column in 0..<(columns - 1) {
                let a = vertex(ring, column), b = vertex(ring, column + 1)
                let c = vertex(ring + 1, column), d = vertex(ring + 1, column + 1)
                indices += [a, c, b, b, c, d]
            }
        }
        return outward(positions: positions, indices: indices)
    }()

    /// WE's fullscreen triangle (0x14019783d), drawn by `volumetrics_fullscreen` and the blur and
    /// combine passes: x and y only.
    static let fullscreenTriangle: [SIMD3<Float>] = [SIMD3(-1, 1, 0), SIMD3(-1, -3, 0), SIMD3(3, 1, 0)]

    /// Swaps the triangles wound inward, judged against the mesh's centroid; degenerate ones are
    /// dropped. The volumes are convex, so outward is away from the centroid.
    static func outward(positions: [SIMD3<Float>], indices: [UInt16]) -> SceneVolumeMesh {
        let centroid = positions.reduce(SIMD3<Float>.zero, +) / Float(positions.count)
        var wound: [UInt16] = []
        for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
            let a = indices[triangle], b = indices[triangle + 1], c = indices[triangle + 2]
            let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
            let normal = simd_cross(pb - pa, pc - pa)
            guard simd_length_squared(normal) > 1e-12 else { continue }
            let outwards = simd_dot(normal, (pa + pb + pc) / 3 - centroid) > 0
            wound += outwards ? [a, b, c] : [a, c, b]
        }
        return SceneVolumeMesh(positions: positions, indices: wound)
    }
}
