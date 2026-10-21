import XCTest
import simd
@testable import OpenWallpaperEngine

private struct NoPropertiesContext: SceneValueContext {
    func userProperty(_ name: String) -> String? { nil }
}

/// WE's light packing (docs/lighting-plan.md §2.2): the sort, the budget, the `LightingV1` arrays
/// and the legacy `g_Lights*`, against values worked out by hand from `wallpaper64.exe`'s packer
/// (0x140190c80) and uniform setter (0x1400d8300).
final class SceneLightPackerTests: XCTestCase {
    private func light(_ kind: WELightKind, color: SIMD3<Float> = SIMD3(repeating: 1), intensity: Float = 1,
                       radius: Float = 1, exponent: Float = 2, shadow: Bool = false, cookie: Bool = false,
                       configure: (inout SceneLight) -> Void = { _ in }) -> SceneLight {
        var light = SceneLight(kind: kind)
        light.color = color
        light.intensity = intensity
        light.radius = radius
        light.exponent = exponent
        light.castShadow = shadow
        light.useCookie = cookie
        configure(&light)
        return light
    }

    private func entry(_ light: SceneLight, at origin: SIMD3<Float> = .zero, angle: Float = 0,
                       scale: SIMD2<Float> = SIMD2(repeating: 1), anglesXY: SIMD2<Float> = .zero,
                       parent: SceneAffineTransform = .identity, visible: Bool = true) -> SceneLightPacker.Light {
        let local = SceneLocalTransform(origin: SIMD2(origin.x, origin.y), scale: scale, angle: angle)
        let depth = SceneLightDepth(originZ: origin.z, anglesXY: anglesXY)
        return SceneLightPacker.Light(light: light, world: SceneFrameLighting.world(parent: parent, local: local, depth: depth),
                                      localOrigin: origin, visible: visible)
    }

    private func pack(_ lights: [SceneLightPacker.Light], _ budget: WELightConfig, shadows: Bool = true,
                      forward: SIMD3<Float> = SIMD3(0, 0, -1)) -> [String: [Float]] {
        SceneLightPacker.lightingV1(lights, budget: budget, shadows: shadows, viewForward: forward)
    }

    private func assertEqual(_ actual: [Float]?, _ expected: [Float], accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual, actual.count == expected.count else {
            return XCTFail("\(String(describing: actual)) ≠ \(expected) \(message)", file: file, line: line)
        }
        for (a, e) in zip(actual, expected) where abs(a - e) > accuracy {
            return XCTFail("\(actual) ≠ \(expected) \(message)", file: file, line: line)
        }
    }

    // MARK: - Each type

    /// `g_LPoint_Color` = (colour·intensity, radius), `g_LPoint_Origin` = (position, exponent);
    /// the budget's second slot stays zero.
    func testPoint() {
        let point = light(.point, color: SIMD3(1, 0.5, 0.25), intensity: 2, radius: 100, exponent: 3)
        let arrays = pack([entry(point, at: SIMD3(10, 20, 5))], WELightConfig(point: 2))
        assertEqual(arrays["g_LPoint_Color"], [2, 1, 0.5, 100, 0, 0, 0, 0])
        assertEqual(arrays["g_LPoint_Origin"], [10, 20, 5, 3, 0, 0, 0, 0])
        XCTAssertEqual(Set(arrays.keys), ["g_LPoint_Color", "g_LPoint_Origin"], "only the budget's arrays")
    }

    /// Origin.w and Direction.w are the cosines of the half-angles in degrees; the direction is
    /// the light's local +X in the world, scale included and not normalised; only
    /// `g_LSpot_Exponent.x` is written.
    func testSpot() {
        let spot = light(.spot, intensity: 4, radius: 50, exponent: 1.5) {
            $0.innerCone = 60
            $0.outerCone = 90
        }
        // A quarter turn takes local +X to (0, 1), as WE's `Rz` does.
        let arrays = pack([entry(spot, at: SIMD3(1, 2, 3), angle: .pi / 2, scale: SIMD2(2, 1))], WELightConfig(spot: 1))
        assertEqual(arrays["g_LSpot_Color"], [4, 4, 4, 50])
        assertEqual(arrays["g_LSpot_Origin"], [1, 2, 3, 0.5])
        assertEqual(arrays["g_LSpot_Direction"], [0, 2, 0, cos(Float(Double.pi / 2))])
        assertEqual(arrays["g_LSpot_Exponent"], [1.5, 0, 0, 0])
    }

    /// Tilting a light out of the plane: WE's `Rz·Ry·Rx` (0x1401dd630) takes local +X to
    /// (cos y cos z, cos y sin z, −sin y) at z = 0.
    func testSpotTiltedOutOfThePlane() {
        let arrays = pack([entry(light(.spot), anglesXY: SIMD2(0.3, .pi / 2))], WELightConfig(spot: 1))
        assertEqual(Array(arrays["g_LSpot_Direction"]![0..<3]), [0, 0, -1])
    }

    /// End A is the light's position with the exponent; end B is `controlpoint` through the
    /// light's world matrix, parents included, with w = 0.
    func testTubeFollowsItsParent() {
        let tube = light(.tube, intensity: 10, radius: 500, exponent: 2) { $0.controlPoint = SIMD3(0, 50, 0) }
        let parent = SceneAffineTransform(linear: simd_float2x2(diagonal: SIMD2(2, 2)), translation: SIMD2(100, 0))
        let arrays = pack([entry(tube, at: SIMD3(10, 0, 7), parent: parent)], WELightConfig(tube: 1))
        assertEqual(arrays["g_LTube_Color"], [10, 10, 10, 500])
        assertEqual(arrays["g_LTube_OriginA"], [120, 0, 7, 2])
        assertEqual(arrays["g_LTube_OriginB"], [120, 100, 7, 0])
    }

    /// (colour·intensity, 1) and the direction toward the light, −local +X; the slots no light
    /// takes point at (0, 1, 0) with no colour.
    func testDirectionalAndItsUnusedSlots() {
        let sun = light(.directional, color: SIMD3(1, 0.5, 0), intensity: 2)
        let arrays = pack([entry(sun)], WELightConfig(directional: 3))
        assertEqual(arrays["g_LDirectional_Color"], [2, 1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0])
        assertEqual(arrays["g_LDirectional_Direction"], [-1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0])
    }

    /// The shadow projections stay zero (shadows and cookies aren't drawn yet) but have their
    /// budget's size: F = SSC + SC + SS + 3·DS projections, PS point projections.
    func testFeatureArraysAreSizedByTheBudget() {
        let arrays = pack([], WELightConfig(spot: 3, directional: 1, spotShadow: 1, spotCookie: 1,
                                            directionalShadow: 1, pointShadow: 1))
        XCTAssertEqual(arrays["g_LFeature_ShadowProjection"], [Float](repeating: 0, count: 5 * 16))
        XCTAssertEqual(arrays["g_LFeature_ShadowProjectionTransform"], [Float](repeating: 0, count: 5 * 4))
        XCTAssertEqual(arrays["g_LFeature_ShadowPointProjection"], [Float](repeating: 0, count: 4))
        XCTAssertNil(arrays["g_LPoint_Color"], "no point budget, no point arrays")
    }

    // MARK: - Sort and budget

    /// By type, then shadow and cookie flags descending, then depth along the view axis
    /// ascending, measured on the light's own origin.
    func testSortOrder() {
        let lights = [
            entry(light(.tube, intensity: 1)),
            entry(light(.point, intensity: 2), at: SIMD3(0, 0, 5)),
            entry(light(.point, intensity: 3), at: SIMD3(0, 0, 1)),
            entry(light(.spot, intensity: 4)),
            entry(light(.spot, intensity: 5, shadow: true)),
            entry(light(.spot, intensity: 6, cookie: true)),
            entry(light(.spot, intensity: 7, shadow: true, cookie: true)),
            entry(light(.directional, intensity: 8)),
            entry(light(.legacyPoint, intensity: 9)),
        ]
        let order = SceneLightPacker.sorted(lights, viewForward: SIMD3(0, 0, 1)).map(\.light.intensity)
        XCTAssertEqual(order, [3, 2, 7, 6, 5, 4, 1, 8, 9])
        XCTAssertEqual(SceneLightPacker.sorted(lights, viewForward: SIMD3(0, 0, -1)).map(\.light.intensity).prefix(2), [2, 3])
    }

    /// Each spot group starts where the budget puts it: shadow and cookie, cookie, shadow, plain.
    func testSpotGroups() {
        let lights = [
            entry(light(.spot, intensity: 4)),
            entry(light(.spot, intensity: 5, shadow: true)),
            entry(light(.spot, intensity: 6, cookie: true)),
            entry(light(.spot, intensity: 7, shadow: true, cookie: true)),
        ]
        let arrays = pack(lights, WELightConfig(spot: 4, spotShadow: 1, spotCookie: 1, spotShadowCookie: 1))
        let colors = arrays["g_LSpot_Color"]!
        XCTAssertEqual([colors[0], colors[4], colors[8], colors[12]], [7, 6, 5, 4])
    }

    /// A type's budget keeps its first lights in sort order; hidden lights don't use it.
    func testBudgetTruncatesAndSkipsHiddenLights() {
        let lights = [
            entry(light(.tube, intensity: 1), at: SIMD3(0, 0, 3)),
            entry(light(.tube, intensity: 2), at: SIMD3(0, 0, 1)),
            entry(light(.tube, intensity: 3), at: SIMD3(0, 0, 2), visible: false),
            entry(light(.tube, intensity: 4), at: SIMD3(0, 0, 4)),
        ]
        let colors = pack(lights, WELightConfig(tube: 2), forward: SIMD3(0, 0, 1))["g_LTube_Color"]!
        XCTAssertEqual([colors[0], colors[4]], [2, 1])
    }

    /// WE doesn't check a group against its own budget: a cookie spot without `spotcookie` starts
    /// where the plain spots do, and the plain spot after it overwrites it.
    func testOverfullGroupWritesOverTheNext() {
        let lights = [entry(light(.spot, intensity: 1)), entry(light(.spot, intensity: 2, cookie: true))]
        let colors = pack(lights, WELightConfig(spot: 2))["g_LSpot_Color"]!
        XCTAssertEqual(colors, [1, 1, 1, 1, 0, 0, 0, 0])
    }

    /// With shadows off, the budget is folded and a shadowed cookie spot packs as a cookie spot.
    func testShadowsOffFoldTheBudget() {
        var content = SceneLightingContent()
        content.settings.lightConfig = WELightConfig(spot: 2, spotShadow: 1, spotShadowCookie: 1)
        content.lights = [
            SceneLightObject(id: "1", authored: WESceneLight(kind: .spot), light: light(.spot, intensity: 1, shadow: true)),
            SceneLightObject(id: "2", authored: WESceneLight(kind: .spot),
                             light: light(.spot, intensity: 2, shadow: true, cookie: true)),
        ]
        var input = frameInput(locals: ["1": .identity, "2": .identity])
        input.shadows = false
        let colors = SceneFrameLighting.frame(content, input: input).arrays["g_LSpot_Color"]!
        // Folded: spot 2, spotcookie 1. The cookie spot takes slot 0 (the cookie group); the
        // shadowed spot packs as plain, from slot 1.
        XCTAssertEqual([colors[0], colors[4]], [2, 1])
    }

    // MARK: - How many lights, and which (docs/lighting-plan.md §2.2, "Light count")

    /// 256 point lights (the user's 3D test in WE's editor: intensity 5, radius 5, exponent 2, no
    /// shadow). The editor writes `lightconfig.point` = min(count, 15) (wallpaperui.exe
    /// 0x14041cd30), so the shaders get 15 point slots, and the packer keeps the 15 first in sort
    /// order: those nearest the eye along the view (WE's "only display the closest lights").
    /// Nothing else is dropped, in a 2D or a 3D scene.
    func testTwoHundredFiftySixPointLightsKeepTheFifteenClosest() {
        // Scattered depths; the view looks down −z, so the largest z is the closest.
        let depths = (0..<256).map { Float(($0 * 97) % 256) }
        let lights = depths.map { entry(light(.point, intensity: 5, radius: 5, exponent: 2), at: SIMD3(0, 0, $0)) }
        let arrays = pack(lights, WELightConfig(point: 15))
        let colors = arrays["g_LPoint_Color"]!, origins = arrays["g_LPoint_Origin"]!
        XCTAssertEqual(colors.count, 15 * 4)
        XCTAssertEqual(colors, [Float]((0..<15).flatMap { _ in [5, 5, 5, 5] }), "every slot holds a light")
        let closest: [Float] = (241...255).reversed().map { Float($0) }
        let packedDepths: [Float] = (0..<15).map { (slot: Int) -> Float in origins[4 * slot + 2] }
        XCTAssertEqual(packedDepths, closest)

        // The frame path doesn't cap them either: all 256 are placed, 15 packed.
        var content = SceneLightingContent()
        content.settings.lightConfig = WELightConfig(point: 15)
        content.lights = depths.enumerated().map { index, z in
            SceneLightObject(id: "\(index)", authored: WESceneLight(kind: .point),
                             light: light(.point, intensity: 5, radius: 5), depth: SceneLightDepth(originZ: z))
        }
        let locals = Dictionary(uniqueKeysWithValues: content.lights.map {
            ($0.id, SceneLocalTransform(origin: .zero, scale: SIMD2(repeating: 1), angle: 0))
        })
        let frame = SceneFrameLighting.frame(content, input: frameInput(locals: locals))
        XCTAssertEqual(frame.objects.count, 256)
        let frameOrigins: [Float] = frame.arrays["g_LPoint_Origin"]!
        let frameDepths: [Float] = (0..<15).map { (slot: Int) -> Float in frameOrigins[4 * slot + 2] }
        XCTAssertEqual(frameDepths, closest)
    }

    /// `castshadow` doesn't decide whether a light lights a surface: a light without it packs, and
    /// every `LIGHTING` material reads every packed light. It only sorts: a shadowed light goes
    /// before its type's plain ones (the comparator 0x14019f490 reads `flags & 3` whether or not
    /// the user's shadows are on), so with a full budget it wins over a closer plain light.
    func testCastShadowSortsButDoesNotSelect() {
        let plainNear = entry(light(.point, intensity: 1), at: SIMD3(0, 0, 9))
        let shadowedFar = entry(light(.point, intensity: 2, shadow: true), at: SIMD3(0, 0, 1))
        let both = pack([plainNear, shadowedFar], WELightConfig(point: 2), shadows: false)["g_LPoint_Color"]!
        XCTAssertEqual([both[0], both[4]], [2, 1], "both lights pack; the shadowed one sorts first")
        let plainOnly = pack([plainNear], WELightConfig(point: 1))["g_LPoint_Color"]!
        XCTAssertEqual(plainOnly, [1, 1, 1, 1], "a light without castshadow lights")
        for shadows in [false, true] {
            let one = pack([plainNear, shadowedFar], WELightConfig(point: 1, pointShadow: shadows ? 1 : 0),
                           shadows: shadows)["g_LPoint_Color"]!
            XCTAssertEqual(one[0], 2, "a budget of one keeps the shadowed light (shadows \(shadows))")
        }
    }

    // MARK: - Frame lighting

    private func frameInput(locals: [String: SceneLocalTransform], parents: [String: SceneAffineTransform] = [:],
                            hidden: Set<String> = []) -> SceneFrameLightingInput {
        SceneFrameLightingInput(local: { locals[$0] }, parentWorld: { parents[$0] ?? .identity },
                                isVisible: { !hidden.contains($0) }, sceneColor: { _ in nil },
                                eyePosition: .zero, viewForward: SIMD3(0, 0, -1))
    }

    /// Without `lightconfig` WE packs no new-style light (0x140190cab); the legacy slots still fill.
    func testNoLightConfigPacksNoLightingV1Light() {
        var content = SceneLightingContent()
        content.lights = [SceneLightObject(id: "1", authored: WESceneLight(kind: .point), light: light(.point, intensity: 3))]
        let arrays = SceneFrameLighting.frame(content, input: frameInput(locals: ["1": .identity])).arrays
        XCTAssertEqual(Set(arrays.keys), ["g_LightsColorRadius", "g_LightsPosition", "g_LightsColorPremultiplied"])
        XCTAssertTrue(arrays.values.allSatisfy { $0.allSatisfy { $0 == 0 } }, "no legacy light either")
    }

    /// A parented light follows its parent's live transform; its own depth stays.
    func testFrameLightingFollowsTheParent() {
        var content = SceneLightingContent()
        content.settings.lightConfig = WELightConfig(point: 1)
        content.lights = [SceneLightObject(id: "7", authored: WESceneLight(kind: .point), light: light(.point, exponent: 4),
                                           depth: SceneLightDepth(originZ: 250))]
        let local = SceneLocalTransform(origin: SIMD2(10, 20), scale: SIMD2(repeating: 1), angle: 0)
        let parent = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(50, 0))
        let arrays = SceneFrameLighting.frame(content, input: frameInput(locals: ["7": local], parents: ["7": parent])).arrays
        assertEqual(arrays["g_LPoint_Origin"], [60, 20, 250, 4])
        let hidden = SceneFrameLighting.frame(content, input: frameInput(locals: ["7": local], hidden: ["7"])).arrays
        assertEqual(hidden["g_LPoint_Origin"], [0, 0, 0, 0], "a hidden light isn't packed")
    }

    // MARK: - Legacy

    /// Every light takes a slot at construction, the first free of 0–3, then slot 0; only legacy
    /// points write theirs. Hidden: (0, 0, 0, 1), with the position still written. The
    /// premultiplied array spreads slot 3's colour over the `w`s.
    func testLegacySlots() {
        XCTAssertEqual(SceneLightPacker.legacySlots(count: 6), [0, 1, 2, 3, 0, 0])
        let lights = [
            entry(light(.legacyPoint, intensity: 7, radius: 9), at: SIMD3(1, 1, 1)),
            entry(light(.legacyPoint, intensity: 1), at: SIMD3(2, 3, 4), visible: false),
            entry(light(.tube, intensity: 5)),
            entry(light(.legacyPoint, color: SIMD3(1, 0, 0), intensity: 2, radius: 3), at: SIMD3(5, 6, 7)),
            entry(light(.legacyPoint, intensity: 0.5, radius: 2), at: SIMD3(8, 9, 10)),
        ]
        let arrays = SceneLightPacker.legacy(lights)
        assertEqual(arrays["g_LightsColorRadius"], [0.5, 0.5, 0.5, 2, 0, 0, 0, 1, 0, 0, 0, 0, 2, 0, 0, 3],
                    "the fifth light shares slot 0 and, updated later, wins it")
        assertEqual(arrays["g_LightsPosition"], [8, 9, 10, 2, 3, 4, 0, 0, 0, 5, 6, 7])
        assertEqual(arrays["g_LightsColorPremultiplied"], [2, 2, 2, 18, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - Uniforms

    /// The built-ins read the frame lighting, zero-padded to the shader's array; the invented
    /// 0.2 and 0.3 ambient and skylight are gone.
    func testBuiltinsReadTheFrameLighting() {
        var frame = BuiltinFrameContext()
        let pass = BuiltinPassContext(targetSize: SIMD2(1, 1))
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LightAmbientColor", frame: frame, pass: pass), [0, 0, 0],
                       "WE's constructor zeroes the scene colours")
        frame.lighting.ambient = SIMD3(0.3, 0.2, 0.1)
        frame.lighting.skylight = SIMD3(0.4, 0.5, 0.6)
        frame.lighting.arrays["g_LTube_Color"] = [1, 2, 3, 4]
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LightAmbientColor", frame: frame, pass: pass), [0.3, 0.2, 0.1])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LightSkylightColor", frame: frame, pass: pass), [0.4, 0.5, 0.6])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LTube_Color", frame: frame, pass: pass, arrayCount: 2),
                       [1, 2, 3, 4, 0, 0, 0, 0])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LTube_Color", frame: frame, pass: pass), [1, 2, 3, 4])
        XCTAssertEqual(BuiltinUniforms.value(named: "g_LightsPosition", frame: frame, pass: pass, arrayCount: 4),
                       [Float](repeating: 0, count: 12), "vec3[4]")
        for name in ["g_LPoint_Color", "g_LFeature_ShadowProjection", "g_LightsColorPremultiplied", "g_LightSkylightColor"] {
            XCTAssertTrue(BuiltinUniforms.isBuiltin(name), name)
            XCTAssertTrue(UniformProgram.timeVarying.contains(name), "\(name) is written every frame")
        }
    }

    // MARK: - One piece girls

    /// One piece girls (3270035750): 4 `ltube` lights under `{"tube": 4}`, copied from its
    /// `scene.json`. By hand: colour (1,1,1)·10 with radius 500; end A the origin with exponent 2;
    /// end B the origin plus `controlpoint` (1.87891, 1131.81885, 0). All four lie at z = 250, so
    /// the depth ties and they keep scene order.
    static let onePieceTubes = """
    [{"color": "1.00000 1.00000 1.00000", "controlpoint": "1.87891 1131.81885 0.00000", "exponent": 2.0, "id": 116,
      "intensity": 10.0, "light": "ltube", "origin": "641.74176 -45.93243 250.00000", "radius": 500.0},
     {"color": "1.00000 1.00000 1.00000", "controlpoint": "1.87891 1131.81885 0.00000", "exponent": 2.0, "id": 122,
      "intensity": 10.0, "light": "ltube", "origin": "1282.47363 -45.93243 250.00000", "radius": 500.0},
     {"color": "1.00000 1.00000 1.00000", "controlpoint": "1.87891 1131.81885 0.00000", "exponent": 2.0, "id": 123,
      "intensity": 10.0, "light": "ltube", "origin": "1916.88281 -45.93243 250.00000", "radius": 500.0},
     {"color": "1.00000 1.00000 1.00000", "controlpoint": "1.87891 1131.81885 0.00000", "exponent": 2.0, "id": 124,
      "intensity": 10.0, "light": "ltube", "origin": "-1.09746 -45.93243 250.00000", "radius": 500.0}]
    """

    static let onePieceXs: [Float] = [641.74176, 1282.47363, 1916.88281, -1.09746]

    private func assertOnePiecePacking(_ arrays: [String: [Float]], file: StaticString = #filePath, line: UInt = #line) {
        let xs = Self.onePieceXs
        assertEqual(arrays["g_LTube_Color"], Array([[Float]](repeating: [10, 10, 10, 500], count: 4).joined()),
                    file: file, line: line)
        assertEqual(arrays["g_LTube_OriginA"], xs.flatMap { [$0, -45.93243, 250, 2] }, file: file, line: line)
        assertEqual(arrays["g_LTube_OriginB"], xs.flatMap { [$0 + 1.87891, 1085.88642, 250, 0] }, file: file, line: line)
    }

    private func frameLighting(objects: [WESceneObject], general: WESceneGeneral) -> SceneFrameLighting {
        let context = NoPropertiesContext()
        let content = SceneLightingContent(settings: SceneLightingSettings(general, in: context),
                                           lights: SceneContentLoader.lights(in: objects, context: context))
        let locals = Dictionary(uniqueKeysWithValues: objects.compactMap { object in
            object.id.map { (String($0), SceneLocalTransform(object: object)) }
        })
        return SceneFrameLighting.frame(content, input: frameInput(locals: locals))
    }

    func testOnePieceGirlsTubes() throws {
        let objects = try JSONDecoder().decode([WESceneObject].self, from: Data(Self.onePieceTubes.utf8))
        let scene = try decodeTolerant(WEScene.self, from: Fixtures.data("Scenes/lights/general-3270035750.json"))
        XCTAssertEqual(scene.general.lightconfig, WELightConfig(tube: 4))
        let lighting = frameLighting(objects: objects, general: scene.general)
        assertOnePiecePacking(lighting.arrays)
        XCTAssertLessThan(simd_length(lighting.ambient - SIMD3(0.29412, 0.13333, 0.13333)), 1e-5)
    }

    /// The same from the library's own `scene.json`, when it is present.
    func testOnePieceGirlsFromTheLibrary() throws {
        let url = URL(fileURLWithPath: "/Volumes/980Pro/OpenWallpaperStorage/3270035750/scene.json")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "wallpaper library not present")
        let scene = try decodeTolerant(WEScene.self, from: Data(contentsOf: url))
        let lighting = frameLighting(objects: scene.objects, general: scene.general)
        assertOnePiecePacking(lighting.arrays)
        XCTAssertEqual(lighting.arrays["g_LightsColorRadius"], [Float](repeating: 0, count: 16), "no legacy light")
    }
}
