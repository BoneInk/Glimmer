import simd

/// One shadow map of a frame (docs/models-plan.md §2.10): a spot's, one cascade of a directional
/// light, or a point light's cell of six cube faces. The light packer (`SceneLightPacker`) makes
/// them as it packs the lights, the atlas layout places them, and `SceneShadowPass` draws the
/// casters into them.
struct SceneShadowMap: Equatable {
    enum Kind: Equatable {
        case spot, cascade, point
    }

    var kind: Kind
    /// The light object's id: the volumetrics read its transform and projection info.
    var lightID: String
    /// The map's side in texels (`SceneShadowAtlas.mapSize`); a point's cell holds its six faces.
    var size: Int
    /// What the casters are drawn with, one per view (a point's six faces, +X, −X, +Y, −Y, +Z,
    /// −Z), WE's matrices with the render bias (`SceneShadowViews.spotBias`, `pointBias`).
    var renderViews: [simd_float4x4]
    /// The element of `g_LFeature_ShadowProjectionTransform` (spots and cascades) or
    /// `g_LFeature_ShadowPointProjectionTransform` (points) that gets the map's rectangle.
    var transformIndex: Int
    /// The map's corner in the atlas (the layout's).
    var origin = SIMD2<Int>.zero

    var isPoint: Bool { kind == .point }

    /// `…ShadowProjectionTransform`: (x/W, y/H, size/W, size/H) of an atlas of `extent`
    /// (0x1401962b0), which the shaders scale and offset their [0, 1] coordinates by.
    func transform(extent: SIMD2<Int>) -> SIMD4<Float> {
        let w = Float(extent.x), h = Float(extent.y)
        return SIMD4(Float(origin.x) / w, Float(origin.y) / h, Float(size) / w, Float(size) / h)
    }

    /// Each view's rectangle in the atlas (x, y, width, height): the map, or a point's faces of
    /// (size/2) × (size/3), face k at column k % 2 and row k / 2 of its cell (0x140196133…).
    var viewports: [SIMD4<Int>] {
        guard isPoint else { return [SIMD4(origin.x, origin.y, size, size)] }
        let width = size / 2, height = size / 3
        return (0..<6).map { k in SIMD4(origin.x + (k % 2) * width, origin.y + (k / 2) * height, width, height) }
    }
}

/// A frame's shadow maps, laid out in the atlas, and what else reads them.
struct SceneShadowFrame: Equatable {
    var maps: [SceneShadowMap] = []
    /// The atlas's size this frame: the layout's, or larger when an earlier frame grew it (WE never
    /// shrinks it). Zero without maps.
    var extent = SIMD2<Int>.zero
    /// Per light id, the light's map transform (light+0x310) and a point's projection info
    /// (light+0x320), which its volume reads (`g_RenderVar0`, `g_RenderVar3`).
    var lightTransforms: [String: SIMD4<Float>] = [:]
    var pointProjections: [String: SIMD4<Float>] = [:]

    /// Places `maps` in an atlas at least `minimumExtent` big (`SceneShadowAtlasLayout`).
    mutating func layOut(minimumExtent: SIMD2<Int>) {
        guard !maps.isEmpty else { return }
        let layout = SceneShadowAtlasLayout.pack(maps.map { SceneShadowAtlasLayout.Map(size: $0.size, isPoint: $0.isPoint) })
        for index in maps.indices {
            maps[index].origin = SIMD2(layout.placements[index].x, layout.placements[index].y)
        }
        extent = simd_max(layout.extent, minimumExtent)
    }
}

/// The views of WE's shadow maps (0x140190c80's per-light blocks, docs/models-plan.md §2.10).
/// Matrices are simd column-vector ones, whose memory is WE's row-vector matrix (column i = WE's
/// row i): WE's `M[3][2]` is `columns.3.z`.
enum SceneShadowViews {
    /// The render matrices' extra depth bias, only where the casters are drawn (the shaders get
    /// the unbiased matrices): spots and cascades `VP[3][2] −= 0.0005` (0x14019632a), a point's
    /// projection `P[3][2] −= 0.00333` (0x140193b4c). In reversed depth both push a caster away
    /// from the light.
    static let spotBias: Float = 0.0005
    static let pointBias: Float = 0.00333

    /// `m` with `M[3][2]` lowered by `bias`.
    static func biased(_ m: simd_float4x4, by bias: Float) -> simd_float4x4 {
        var result = m
        result.columns.3.z -= bias
        return result
    }

    // MARK: Spot

    /// A spot's view-projection (light+0x338, 0x14025d420): the volumetrics' light projection.
    static func spot(_ light: SceneLight, world: simd_float4x4, orthographic: Bool) -> simd_float4x4 {
        SceneVolumetricLight.spotProjection(light: light, world: world, orthographic: orthographic)
    }

    // MARK: Point

    /// A point light's cube faces' field of view in degrees (0x14025d9c1): 94 at low and medium,
    /// 92 at high, 91.2 at ultra, a little over 90 so the faces overlap (the shaders' 0.47, 0.48,
    /// 0.49 compensation).
    static func pointFieldOfView(quality: Int) -> Float {
        switch quality {
        case ...2: return 94
        case 3: return 92
        default: return 91.2
        }
    }

    /// A point light's projection (light+0x338): aspect 1, near `max(0.05, lightsourcesize)`
    /// (1 in an orthographic scene), far `max(radius, near + 0.01)`, reversed.
    static func pointProjection(_ light: SceneLight, quality: Int, orthographic: Bool) -> simd_float4x4 {
        let near = orthographic ? 1 : max(0.05, light.lightSourceSize)
        let far = max(light.radius, near + 0.01)
        return SceneCamera.perspective(fovDegrees: pointFieldOfView(quality: quality), aspect: 1, near: near, far: far)
    }

    /// `g_LFeature_ShadowPointProjection` (light+0x320): (P22, P32, P23, P33).
    static func projectionInfo(_ projection: simd_float4x4) -> SIMD4<Float> {
        SIMD4(projection.columns.2.z, projection.columns.3.z, projection.columns.2.w, projection.columns.3.w)
    }

    /// The six faces' views about `origin`, +X, −X, +Y, −Y, +Z, −Z: the bases
    /// `CalculateProjectedCoordsPoint` (`common_pbr_2.h`) picks by the largest component of
    /// `world − origin`.
    static func pointFaceViews(origin o: SIMD3<Float>) -> [simd_float4x4] {
        [
            simd_float4x4(columns: (SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(-o.z, -o.y, o.x, 1))),
            simd_float4x4(columns: (SIMD4(0, 0, 1, 0), SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(o.z, -o.y, -o.x, 1))),
            simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(-o.x, -o.z, o.y, 1))),
            simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, -1, 0, 0), SIMD4(-o.x, o.z, -o.y, 1))),
            simd_float4x4(columns: (SIMD4(-1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(o.x, -o.y, o.z, 1))),
            simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(-o.x, -o.y, -o.z, 1))),
        ]
    }

    /// The faces' render matrices: each face's view through the biased projection.
    static func pointRenderViews(projection: simd_float4x4, origin: SIMD3<Float>) -> [simd_float4x4] {
        let biased = biased(projection, by: pointBias)
        return pointFaceViews(origin: origin).map { biased * $0 }
    }

    // MARK: Directional

    /// The cascades' (box size, depth range) from `cascadedistance0…2` (0x14025d370):
    /// (c0, 4·c1), (c1, 4·c1), (c2, max(1.5·c2, 4·c1)).
    static func cascadePairs(_ c: SIMD3<Float>) -> [SIMD2<Float>] {
        [SIMD2(c.x, 4 * c.y), SIMD2(c.y, 4 * c.y), SIMD2(c.z, max(1.5 * c.z, 4 * c.y))]
    }

    /// A directional light's three cascades' view-projections (0x1401912a0…0x140192a0e).
    ///
    /// Per cascade of box size b and depth range d: `F′ = F − ½(F·L)L` with the camera's forward F
    /// and the light's normalised row 0 L; the centre `eye + F′·b/2` (its z 0 in an orthographic
    /// scene); snapped to texels of b / mapSize along the light's rows 1 and 2 (each by the
    /// remainder of the centre's dot product with the row, `fmodf`, rows as they stand); the view
    /// the rigid inverse of the basis (row 2, row 1, −row 0) normalised, at the centre; and
    /// `ortho(±b/2, ±b/2, z ±d/2)`, reversed (depth 1 toward the light).
    static func cascades(world: simd_float4x4, distances: SIMD3<Float>, mapSize: Int, eye: SIMD3<Float>,
                         forward: SIMD3<Float>, orthographic: Bool) -> [simd_float4x4] {
        let row0 = world.columns.0.xyz, row1 = world.columns.1.xyz, row2 = world.columns.2.xyz
        let direction = simd_normalize(row0)
        let spread = forward - 0.5 * simd_dot(forward, direction) * direction
        let basis = (x: simd_normalize(row2), y: simd_normalize(row1), z: simd_normalize(-row0))
        return cascadePairs(distances).map { pair in
            let half = pair.x * 0.5, halfDepth = pair.y * 0.5
            var centre = eye + spread * half
            if orthographic { centre.z = 0 }
            let texel = pair.x / Float(mapSize)
            let along2 = simd_dot(row2, centre)
            centre -= row1 * fmodf(simd_dot(row1, centre), texel)
            centre -= row2 * fmodf(along2, texel)
            let view = simd_float4x4(rows: [
                SIMD4(basis.x, -simd_dot(basis.x, centre)),
                SIMD4(basis.y, -simd_dot(basis.y, centre)),
                SIMD4(basis.z, -simd_dot(basis.z, centre)),
                SIMD4(0, 0, 0, 1),
            ])
            let projection = SceneCamera.orthographic(left: -half, right: half, bottom: -half, top: half,
                                                      near: -halfDepth, far: halfDepth)
            return projection * view
        }
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
