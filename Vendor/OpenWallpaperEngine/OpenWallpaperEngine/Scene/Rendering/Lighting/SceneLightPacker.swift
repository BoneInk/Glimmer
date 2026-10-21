import simd

/// Packs the scene's lights into WE's light uniforms, as `wallpaper64.exe` does every frame
/// (docs/lighting-plan.md §2.2).
///
/// - **`LightingV1` arrays** (`g_LPoint_*`, `g_LSpot_*`, `g_LTube_*`, `g_LDirectional_*`,
///   `g_LFeature_*`): the packer at 0x140190c80. It sorts every light (0x140186990, comparator
///   0x14019f490), walks them in order and writes each visible one that fits its type's budget
///   into one zeroed buffer of vec4s (0x1404217a0), laid out as the `LightingV1` uniforms are
///   declared. Without `lightconfig` it returns before doing anything (0x140190cab).
/// - **Legacy arrays** (`g_LightsColorRadius`, `g_LightsPosition`, `g_LightsColorPremultiplied`):
///   each legacy `point` light writes its fixed slot every frame (0x14025d1f0), and the uniform
///   setter (0x1400d8300) premultiplies the colours.
enum SceneLightPacker {
    /// A light as the packer reads it this frame.
    struct Light {
        var light: SceneLight
        /// The light's world matrix (column-major: column 0 is WE's row 0, the light's local +X in
        /// the world; column 3 is its position).
        var world: simd_float4x4
        /// The light's own `origin`, relative to its parent: the sort key reads it (the object's
        /// +0x128 at 0x140186a42), not the world position.
        var localOrigin: SIMD3<Float>
        /// Its own `visible` and every ancestor's (0x140185010).
        var visible: Bool
        /// The light object's id (its shadow map's, `SceneShadowMap.lightID`).
        var id = ""
    }

    /// What the shadow maps are made from (docs/models-plan.md §2.10): the user's shadows setting
    /// (1 low … 4 ultra; 0 makes none), the camera the cascades follow (ctx+0x68, ctx+0x160), the
    /// scene's projection, and the atlas's size so far, which the layout never shrinks.
    struct ShadowContext: Equatable {
        var quality: Int
        /// "Cheaper shadows": the maps are drawn smaller (`SceneShadowAtlas.mapSize`).
        var reduced = false
        var eye: SIMD3<Float>
        var forward: SIMD3<Float>
        var orthographic: Bool
        var atlasExtent = SIMD2<Int>.zero
    }

    /// The `LightingV1` arrays by uniform name, flattened per element (`vec4` 4 floats, `mat4`
    /// 16). Only arrays the budget gives at least one element are present.
    ///
    /// `budget` is the one the shaders were built with: folded by `withShadowsDisabled` when the
    /// user's shadows are off, which `shadows` also says (WE reads it from ctx+0x1ac).
    static func lightingV1(_ lights: [Light], budget: WELightConfig, shadows: Bool,
                           viewForward: SIMD3<Float>) -> [String: [Float]] {
        lightingV1(lights, budget: budget, shadows: shadows, viewForward: viewForward, shadowContext: nil).arrays
    }

    /// The same, with the shadow and cookie projections (`g_LFeature_*`) and the frame's shadow
    /// maps laid out in the atlas (0x140190c80 through 0x1401939ed), when `shadowContext` is given.
    static func lightingV1(_ lights: [Light], budget: WELightConfig, shadows: Bool, viewForward: SIMD3<Float>,
                           shadowContext: ShadowContext?) -> (arrays: [String: [Float]], shadows: SceneShadowFrame) {
        var buffer = LightBuffer(budget, shadowContext: shadowContext)
        for entry in sorted(lights, viewForward: viewForward) where entry.visible {
            buffer.pack(entry, shadows: shadows)
        }
        buffer.fillUnusedDirectionals()
        buffer.layOutShadows()
        return (buffer.arrays, buffer.shadowFrame)
    }

    /// The light whose cookie is `_alias_lightCookie` this frame (`SceneLightCookie`): the last
    /// visible spot with `usecookie` that the packer walks within the spot budget, in its sort
    /// order (0x140192ee5…0x140192f0b, then 0x1401935a2); nil when it packs none.
    static func cookieLight(_ lights: [Light], budget: WELightConfig, viewForward: SIMD3<Float>) -> String? {
        var spots = budget.spot
        var cookie: String?
        for entry in sorted(lights, viewForward: viewForward) where entry.visible && entry.light.kind == .spot {
            guard spots > 0 else { break }
            spots -= 1
            if entry.light.useCookie { cookie = entry.id }
        }
        return cookie
    }

    /// WE's order: by type, then by shadow and cookie flags descending (shadow and cookie,
    /// cookie, shadow, none), then by `dot(local origin, view forward)` ascending. WE's
    /// `std::sort` leaves ties in no set order; here they keep scene order.
    static func sorted(_ lights: [Light], viewForward: SIMD3<Float>) -> [Light] {
        let keyed = lights.enumerated().map { index, light in
            (light: light, index: index, type: light.light.kind.rawValue, flags: flags(of: light.light),
             depth: simd_dot(light.localOrigin, viewForward))
        }
        return keyed.sorted { a, b in
            if a.type != b.type { return a.type < b.type }
            if a.flags != b.flags { return a.flags > b.flags }
            if a.depth != b.depth { return a.depth < b.depth }
            return a.index < b.index
        }.map(\.light)
    }

    /// Bits 0 (`castshadow`) and 1 (`usecookie`) of the light's flags (0x2c4 & 3).
    static func flags(of light: SceneLight) -> Int {
        (light.castShadow ? 1 : 0) | (light.useCookie ? 2 : 0)
    }

    // MARK: - Legacy

    /// The legacy slots of the scene's lights, in scene order. The constructor (0x1401903c4)
    /// gives every light, whatever its type, the first of slots 0–3 no earlier light holds, and
    /// slot 0 once all four are taken; only legacy `point` lights write theirs.
    static func legacySlots(count: Int) -> [Int] {
        (0..<count).map { $0 < legacySlotCount ? $0 : 0 }
    }

    static let legacySlotCount = 4

    /// `g_LightsColorRadius` (vec4[4]), `g_LightsPosition` (vec3[4]) and
    /// `g_LightsColorPremultiplied` (vec4[3]). `lights` is every light in scene order; a later
    /// light that shares a slot overwrites an earlier one, as its per-frame update runs later.
    static func legacy(_ lights: [Light]) -> [String: [Float]] {
        // The scene context starts with every slot zeroed (0x14017ce13…0x14017ce3d).
        var colorRadius = [SIMD4<Float>](repeating: .zero, count: legacySlotCount)
        var position = [SIMD3<Float>](repeating: .zero, count: legacySlotCount)
        for (entry, slot) in zip(lights, legacySlots(count: lights.count)) where entry.light.kind == .legacyPoint {
            colorRadius[slot] = entry.visible ? SIMD4(entry.light.color * entry.light.intensity, entry.light.radius)
                : SIMD4(0, 0, 0, 1)
            // The position is written whether or not the light is shown.
            position[slot] = entry.world.columns.3.xyz
        }
        return [
            "g_LightsColorRadius": colorRadius.flatMap(\.components),
            "g_LightsPosition": position.flatMap { [$0.x, $0.y, $0.z] },
            "g_LightsColorPremultiplied": premultiplied(colorRadius).flatMap(\.components),
        ]
    }

    /// The setter at 0x1400d99b1: `out[k].rgb = L_k.rgb·r_k²` for slots 0–2, and slot 3's colour
    /// spread over the three `w`s: `out[k].w = L_3.rgb[k]·r_3²`.
    static func premultiplied(_ colorRadius: [SIMD4<Float>]) -> [SIMD4<Float>] {
        let last = colorRadius[3]
        let lastScale = last.w * last.w
        return (0..<3).map { k in
            let light = colorRadius[k]
            let scale = light.w * light.w
            return SIMD4(light.xyz * scale, last[k] * lastScale)
        }
    }

    /// Each legacy uniform's floats per element, as WE's shaders declare them.
    static let legacyComponents: [String: Int] = [
        "g_LightsColorRadius": 4, "g_LightsPosition": 3, "g_LightsColorPremultiplied": 4,
    ]

    /// Each `LightingV1` uniform's floats per element (0x140169140's declarations).
    static let lightingV1Components: [String: Int] = [
        "g_LPoint_Color": 4, "g_LPoint_Origin": 4,
        "g_LSpot_Color": 4, "g_LSpot_Origin": 4, "g_LSpot_Direction": 4, "g_LSpot_Exponent": 4,
        "g_LTube_Color": 4, "g_LTube_OriginA": 4, "g_LTube_OriginB": 4,
        "g_LDirectional_Color": 4, "g_LDirectional_Direction": 4,
        "g_LFeature_ShadowProjection": 16, "g_LFeature_ShadowProjectionTransform": 4,
        "g_LFeature_ShadowPointProjection": 4, "g_LFeature_ShadowPointProjectionTransform": 4,
    ]
}

/// The packer's one buffer of vec4s and its cursors (0x140190d97…0x140191063).
///
/// The arrays follow each other in declaration order, and each type's lights are grouped by
/// their flags: shadowed points first; spots with shadow and cookie, then cookie, then shadow,
/// then plain; shadowed directionals first. Each group's cursor starts where its budget says and
/// is never checked against the group's size, so a light past its group's budget writes into
/// the next group, or the next array, as it does in WE. Writes past the buffer's end, which would
/// corrupt WE's memory, are dropped.
private struct LightBuffer {
    private let budget: WELightConfig
    /// `F`: one shadow projection per shadowed or cookie spot, three per shadowed directional.
    private let features: Int
    private var floats: [Float]
    private var remaining: (point: Int, spot: Int, tube: Int, directional: Int)
    /// Indexed by the group: bit 0 shadow, bit 1 cookie.
    private var pointCursor: [Int]
    private var spotCursor: [Int]
    private var directionalCursor: [Int]
    /// Each directional group's unused slots, which get a placeholder direction at the end.
    private var directionalLeft: [Int]
    private var tubeCursor = 0

    /// The shadow part (0x140190fb8…0x14019105c): how many spot and directional entries may
    /// still get a projection (`F`, one per spot and one per directional light, though a
    /// directional writes three), how many shadowed points may get a cell, and the cursors of the
    /// directionals' cascades and of the points' projections.
    private let shadowContext: SceneLightPacker.ShadowContext?
    private var featureEntriesLeft: Int
    private var pointShadowsLeft: Int
    private var cascadeCursor: Int
    private var pointShadowCursor = 0
    private(set) var shadowFrame = SceneShadowFrame()

    init(_ budget: WELightConfig, shadowContext: SceneLightPacker.ShadowContext? = nil) {
        self.budget = budget
        self.shadowContext = shadowContext
        featureEntriesLeft = budget.spotShadowCookie + budget.spotCookie + budget.spotShadow + 3 * budget.directionalShadow
        pointShadowsLeft = budget.pointShadow
        cascadeCursor = budget.spotShadowCookie + budget.spotCookie + budget.spotShadow
        features = budget.spotShadowCookie + budget.spotCookie + budget.spotShadow + 3 * budget.directionalShadow
        remaining = (budget.point, budget.spot, budget.tube, budget.directional)
        pointCursor = [budget.pointShadow, 0]
        spotCursor = [budget.spotShadowCookie + budget.spotCookie + budget.spotShadow,
                      budget.spotShadowCookie + budget.spotCookie, budget.spotShadowCookie, 0]
        directionalCursor = [budget.directionalShadow, 0]
        directionalLeft = [budget.directional - budget.directionalShadow, budget.directionalShadow]
        let vectors = 2 * budget.point + 4 * budget.spot + 3 * budget.tube + 2 * budget.directional
            + 5 * features + 2 * budget.pointShadow
        floats = [Float](repeating: 0, count: 4 * vectors)
    }

    // The vec4 offset of each array.
    private var pointBase: Int { 0 }
    private var spotBase: Int { 2 * budget.point }
    private var tubeBase: Int { spotBase + 4 * budget.spot }
    private var directionalBase: Int { tubeBase + 3 * budget.tube }
    private var featureBase: Int { directionalBase + 2 * budget.directional }
    private var pointShadowBase: Int { featureBase + 5 * features }

    mutating func pack(_ entry: SceneLightPacker.Light, shadows: Bool) {
        let light = entry.light
        let world = entry.world
        let color = SIMD4(light.color * light.intensity, light.radius)
        let position = world.columns.3.xyz
        switch light.kind {
        case .point:
            guard remaining.point > 0 else { return }
            remaining.point -= 1
            let group = shadows && light.castShadow ? 1 : 0
            let index = pointBase + pointCursor[group]
            pointCursor[group] += 1
            write(color, at: index)
            write(SIMD4(position, light.exponent), at: index + budget.point)
            if shadows, light.castShadow { packPointShadow(entry) }
        case .spot:
            guard remaining.spot > 0 else { return }
            remaining.spot -= 1
            let group = SceneLightPacker.flags(of: light) & (shadows ? 3 : 2)
            let index = spotBase + spotCursor[group]
            spotCursor[group] += 1
            write(color, at: index)
            write(SIMD4(position, cos(light.innerCone * Self.radiansPerDegree)), at: index + budget.spot)
            // The light's local +X, scale included and not normalised (0x140192e8b).
            write(SIMD4(world.columns.0.xyz, cos(light.outerCone * Self.radiansPerDegree)), at: index + 2 * budget.spot)
            // Only `.x`: the rest keeps whatever the buffer holds.
            write(light.exponent, at: index + 3 * budget.spot, component: 0)
            // The group's projection slot is its cursor, which is the spot's index here.
            packSpotFeature(entry, slot: index - spotBase, shadowed: shadows && light.castShadow)
        case .tube:
            guard remaining.tube > 0 else { return }
            remaining.tube -= 1
            let index = tubeBase + tubeCursor
            tubeCursor += 1
            write(color, at: index)
            write(SIMD4(position, light.exponent), at: index + budget.tube)
            write(SIMD4((world * SIMD4(light.controlPoint, 1)).xyz, 0), at: index + 2 * budget.tube)
        case .directional:
            guard remaining.directional > 0 else { return }
            remaining.directional -= 1
            let group = shadows && light.castShadow ? 1 : 0
            let index = directionalBase + directionalCursor[group]
            directionalCursor[group] += 1
            directionalLeft[group] -= 1
            write(SIMD4(light.color * light.intensity, 1), at: index)
            // Toward the light: the negated local +X.
            write(SIMD4(-world.columns.0.xyz, 0), at: index + budget.directional)
            if shadows, light.castShadow { packCascades(entry) }
        case .legacyPoint:
            return
        }
    }

    /// The directional slots no light took get the direction (0, 1, 0) and no colour (0x1401931bb
    /// for the plain group, then 0x140193530 for the shadowed one). A group overfilled past its
    /// budget has none left.
    mutating func fillUnusedDirectionals() {
        for group in [0, 1] {
            while directionalLeft[group] > 0 {
                directionalLeft[group] -= 1
                write(SIMD4(0, 1, 0, 0), at: directionalBase + directionalCursor[group] + budget.directional)
                directionalCursor[group] += 1
            }
        }
    }

    // MARK: Shadows

    /// A spot with a shadow (shadows on) or a cookie (0x140192ee0…0x140193178): its projection
    /// (light+0x338) goes into `g_LFeature_ShadowProjection` at its group's cursor; only a
    /// shadowed one gets a map, whose rectangle goes into the transform at the same slot.
    private mutating func packSpotFeature(_ entry: SceneLightPacker.Light, slot: Int, shadowed: Bool) {
        guard let context = shadowContext, shadowed || entry.light.useCookie, featureEntriesLeft > 0 else { return }
        featureEntriesLeft -= 1
        let projection = SceneShadowViews.spot(entry.light, world: entry.world, orthographic: context.orthographic)
        writeProjection(projection, slot: slot)
        guard shadowed, context.quality > 0 else { return }
        shadowFrame.maps.append(SceneShadowMap(
            kind: .spot, lightID: entry.id, size: SceneShadowAtlas.mapSize(quality: context.quality, reduced: context.reduced),
            renderViews: [SceneShadowViews.biased(projection, by: SceneShadowViews.spotBias)], transformIndex: slot))
    }

    /// A shadowed directional light (0x14019123d…0x140192a14): one entry of `F`, three cascades
    /// from the cascade cursor. WE's generated shader advances its cascade base by one per light
    /// (`LightingV1Require`), which the cursor here doesn't copy: it writes where WE writes.
    private mutating func packCascades(_ entry: SceneLightPacker.Light) {
        guard let context = shadowContext, context.quality > 0, featureEntriesLeft > 0 else { return }
        featureEntriesLeft -= 1
        let size = SceneShadowAtlas.mapSize(quality: context.quality, reduced: context.reduced)
        let cascades = SceneShadowViews.cascades(world: entry.world, distances: entry.light.cascadeDistances, mapSize: size,
                                                 eye: context.eye, forward: context.forward,
                                                 orthographic: context.orthographic)
        for projection in cascades {
            writeProjection(projection, slot: cascadeCursor)
            shadowFrame.maps.append(SceneShadowMap(
                kind: .cascade, lightID: entry.id, size: size,
                renderViews: [SceneShadowViews.biased(projection, by: SceneShadowViews.spotBias)],
                transformIndex: cascadeCursor))
            cascadeCursor += 1
        }
    }

    /// A shadowed point light (0x14019331d…0x140193526): its projection's info into
    /// `g_LFeature_ShadowPointProjection` and a cell of six faces.
    private mutating func packPointShadow(_ entry: SceneLightPacker.Light) {
        guard let context = shadowContext, context.quality > 0, pointShadowsLeft > 0 else { return }
        pointShadowsLeft -= 1
        let projection = SceneShadowViews.pointProjection(entry.light, quality: context.quality,
                                                          orthographic: context.orthographic)
        let info = SceneShadowViews.projectionInfo(projection)
        write(info, at: pointShadowBase + pointShadowCursor)
        shadowFrame.pointProjections[entry.id] = info
        shadowFrame.maps.append(SceneShadowMap(
            kind: .point, lightID: entry.id, size: SceneShadowAtlas.mapSize(quality: context.quality, reduced: context.reduced),
            renderViews: SceneShadowViews.pointRenderViews(projection: projection, origin: entry.world.columns.3.xyz),
            transformIndex: pointShadowCursor))
        pointShadowCursor += 1
    }

    /// A projection into `g_LFeature_ShadowProjection[slot]`, WE's matrix as it stands.
    private mutating func writeProjection(_ projection: simd_float4x4, slot: Int) {
        guard slot < features else { return }
        let base = featureBase + 4 * slot
        for column in 0..<4 { write(projection[column], at: base + column) }
    }

    /// The atlas layout (0x1401935dc…) and each map's rectangle into its transform (0x1401960b1,
    /// 0x140196269).
    mutating func layOutShadows() {
        guard let context = shadowContext else { return }
        shadowFrame.layOut(minimumExtent: context.atlasExtent)
        for map in shadowFrame.maps {
            let transform = map.transform(extent: shadowFrame.extent)
            if map.isPoint {
                write(transform, at: pointShadowBase + budget.pointShadow + map.transformIndex)
            } else if map.transformIndex < features {
                write(transform, at: featureBase + 4 * features + map.transformIndex)
            }
            // The light's own copy (+0x310), which its volume reads: its last map's.
            shadowFrame.lightTransforms[map.lightID] = transform
        }
    }

    var arrays: [String: [Float]] {
        var result: [String: [Float]] = [:]
        func slice(_ name: String, vectorOffset: Int, count: Int, vectorsPerElement: Int = 1) {
            guard count > 0 else { return }
            let start = 4 * vectorOffset
            result[name] = Array(floats[start..<(start + 4 * vectorsPerElement * count)])
        }
        slice("g_LPoint_Color", vectorOffset: pointBase, count: budget.point)
        slice("g_LPoint_Origin", vectorOffset: pointBase + budget.point, count: budget.point)
        slice("g_LSpot_Color", vectorOffset: spotBase, count: budget.spot)
        slice("g_LSpot_Origin", vectorOffset: spotBase + budget.spot, count: budget.spot)
        slice("g_LSpot_Direction", vectorOffset: spotBase + 2 * budget.spot, count: budget.spot)
        slice("g_LSpot_Exponent", vectorOffset: spotBase + 3 * budget.spot, count: budget.spot)
        slice("g_LTube_Color", vectorOffset: tubeBase, count: budget.tube)
        slice("g_LTube_OriginA", vectorOffset: tubeBase + budget.tube, count: budget.tube)
        slice("g_LTube_OriginB", vectorOffset: tubeBase + 2 * budget.tube, count: budget.tube)
        slice("g_LDirectional_Color", vectorOffset: directionalBase, count: budget.directional)
        slice("g_LDirectional_Direction", vectorOffset: directionalBase + budget.directional, count: budget.directional)
        slice("g_LFeature_ShadowProjection", vectorOffset: featureBase, count: features, vectorsPerElement: 4)
        slice("g_LFeature_ShadowProjectionTransform", vectorOffset: featureBase + 4 * features, count: features)
        slice("g_LFeature_ShadowPointProjection", vectorOffset: pointShadowBase, count: budget.pointShadow)
        slice("g_LFeature_ShadowPointProjectionTransform", vectorOffset: pointShadowBase + budget.pointShadow,
              count: budget.pointShadow)
        return result
    }

    private mutating func write(_ value: SIMD4<Float>, at vector: Int) {
        for component in 0..<4 { write(value[component], at: vector, component: component) }
    }

    private mutating func write(_ value: Float, at vector: Int, component: Int) {
        let index = 4 * vector + component
        guard floats.indices.contains(index) else { return }
        floats[index] = value
    }

    /// WE's degrees-to-radians constant (0x140492628), the float nearest π/180.
    static let radiansPerDegree = Float(Double.pi / 180)
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
    var components: [Float] { [x, y, z, w] }
}
