import XCTest
import simd
@testable import OpenWallpaperEngine

private struct LightPropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    func userProperty(_ name: String) -> String? { properties[name] }
}

/// Light objects, `general.lightconfig` and the lighting and HDR settings of `general`, decoded with
/// WE's defaults (docs/lighting-plan.md §1.1, §1.2). `Scenes/lights` holds light objects copied
/// from the library survey (One piece girls' tube, Hinata's spot, Moon's points, arsenal's and
/// demon_core's legacy points) under Hinata's `general`.
final class SceneLightDecodeTests: XCTestCase {
    private func scene(_ properties: [String: String] = [:]) throws -> WEScene {
        try BoundDocument.decode(WEScene.self, from: Fixtures.data("Scenes/lights/scene.json"), properties: properties)
    }

    private func light(_ id: Int, in scene: WEScene, context: SceneValueContext = LightPropertyContext()) throws -> SceneLight {
        let object = try XCTUnwrap(scene.objects.first { $0.id == id }, "object \(id)")
        return SceneLight(try XCTUnwrap(object.light, "object \(id) is a light"), in: context)
    }

    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-4, "\(a) ≠ \(b) \(message)", file: file, line: line)
    }

    func testEveryLightTypeDecodes() throws {
        let scene = try scene()
        let kinds = Dictionary(uniqueKeysWithValues: scene.objects.compactMap { object in
            object.light.map { (object.id ?? -1, $0.kind) }
        })
        XCTAssertEqual(kinds, [116: .tube, 516: .spot, 39: .point, 285: .point, 2: .legacyPoint, 5: .legacyPoint,
                               900: .directional, 901: .point])
        XCTAssertNil(scene.objects[0].light, "an image layer is no light")
        XCTAssertEqual(WELightKind.allCases.map(\.rawValue), [0, 1, 2, 3, 5], "WE's enum values")
    }

    func testTubeFields() throws {
        let tube = try light(116, in: scene())
        assertEqual(tube.color, SIMD3(1, 1, 1))
        XCTAssertEqual(tube.intensity, 10)
        XCTAssertEqual(tube.radius, 500)
        XCTAssertEqual(tube.exponent, 2)
        assertEqual(tube.controlPoint, SIMD3(1.87891, 1131.81885, 0))
        assertEqual(tube.cascadeDistances, SIMD3(576, 1152, 2112))
        XCTAssertFalse(tube.castShadow)
        XCTAssertEqual(tube.density, 2)
        XCTAssertEqual(tube.volumetricsExponent, 1)
    }

    func testSpotFields() throws {
        let spot = try light(516, in: scene())
        XCTAssertEqual(spot.innerCone, 80)
        XCTAssertEqual(spot.outerCone, 80)
        XCTAssertEqual(spot.radius, 1135.67, accuracy: 1e-3)
        XCTAssertEqual(spot.intensity, 4.12, accuracy: 1e-5)
        XCTAssertEqual(spot.exponent, 1.02, accuracy: 1e-6)
        XCTAssertTrue(spot.useCookie)
        XCTAssertTrue(spot.castVolumetrics)
        XCTAssertFalse(spot.castShadow)
        XCTAssertEqual(spot.density, 1.88, accuracy: 1e-6)
        XCTAssertEqual(spot.volumetricsExponent, 2.55, accuracy: 1e-6)
    }

    func testPointFieldsAndItsObjectsTransform() throws {
        let scene = try scene()
        let moon = try light(39, in: scene)
        assertEqual(moon.color, SIMD3(repeating: 0.45098))
        XCTAssertEqual(moon.intensity, 20.959999, accuracy: 1e-5)
        XCTAssertEqual(moon.radius, 50)
        XCTAssertEqual(moon.exponent, 5)
        XCTAssertEqual(moon.density, 10)
        let hidden = try XCTUnwrap(scene.objects.first { $0.id == 285 })
        XCTAssertEqual(hidden.parent, 1, "a light's parent and visibility are its object's")
        XCTAssertEqual(hidden.visible, false)
        XCTAssertEqual(hidden.scale, "5000.00000 9441.25000 5000.00000")
    }

    /// arsenal's and demon_core's legacy points author colour, intensity and radius only.
    func testLegacyPointKeepsWEsDefaultsForTheRest() throws {
        let legacy = try light(2, in: scene())
        XCTAssertEqual(legacy.kind, .legacyPoint)
        XCTAssertEqual(legacy.intensity, 1.87, accuracy: 1e-6)
        XCTAssertEqual(legacy.radius, 16.32, accuracy: 1e-5)
        var expected = SceneLight(kind: .legacyPoint)
        expected.color = legacy.color
        expected.intensity = legacy.intensity
        expected.radius = legacy.radius
        XCTAssertEqual(legacy, expected)
        assertEqual(try light(5, in: scene()).color, SIMD3(1, 1, 1))
    }

    /// A light that authors nothing but its type has the constructor's values (0x140190457…).
    func testUnauthoredFieldsAreWEsConstructorValues() throws {
        let bare = try light(900, in: scene())
        XCTAssertEqual(bare.kind, .directional)
        assertEqual(bare.color, .zero)
        XCTAssertEqual(bare.intensity, 0)
        XCTAssertEqual(bare.radius, 1)
        XCTAssertEqual(bare.exponent, 2)
        XCTAssertEqual(bare.innerCone, 20)
        XCTAssertEqual(bare.outerCone, 30)
        assertEqual(bare.controlPoint, SIMD3(2, 0, 0))
        XCTAssertFalse(bare.castShadow || bare.useCookie || bare.castVolumetrics)
        XCTAssertEqual(bare.density, 2)
        XCTAssertEqual(bare.volumetricsExponent, 1)
        assertEqual(bare.cascadeDistances, SIMD3(3, 10, 100))
        XCTAssertEqual(bare.lightSourceSize, 0)
    }

    func testBoundFieldsFollowTheirProperties() throws {
        let scene = try scene()
        let authored = try light(901, in: scene)
        XCTAssertEqual(authored.intensity, 3, "no property: the authored value")
        assertEqual(authored.color, SIMD3(1, 0, 0))
        let bound = try light(901, in: try self.scene(["lamp": "7.5", "lampcolor": "0.5"]))
        XCTAssertEqual(bound.intensity, 7.5)
        assertEqual(bound.color, SIMD3(repeating: 0.5), "a scalar sets every channel")
    }

    func testUnknownTypeIsTheLegacyPoint() throws {
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id":3,"light":"laser"}"#.utf8))
        XCTAssertEqual(object.light?.kind, .legacyPoint)
        let notALight = try JSONDecoder().decode(WESceneObject.self, from: Data(#"{"id":4,"light":null}"#.utf8))
        XCTAssertNil(notALight.light)
    }

    // MARK: - lightconfig

    private func config(_ json: String) throws -> WELightConfig {
        try JSONDecoder().decode(WELightConfig.self, from: Data(json.utf8))
    }

    func testLightConfigsOfTheLibrary() throws {
        XCTAssertEqual(try config(#"{"tube":4}"#), WELightConfig(tube: 4))
        XCTAssertEqual(try config(#"{"spot":1,"spotcookie":1}"#), WELightConfig(spot: 1, spotCookie: 1))
        XCTAssertEqual(try config(#"{"point":3}"#), WELightConfig(point: 3))
        XCTAssertEqual(try scene().general.lightconfig, WELightConfig(spot: 1, spotCookie: 1))
    }

    /// Counts are masked to WE's field widths (4 bits, 2 for subsets); a non-number is skipped.
    func testLightConfigMasksLikeWE() throws {
        let masked = try config(#"{"point":20,"directional":15,"spotshadow":5,"pointshadow":2.9,"tube":"4"}"#)
        XCTAssertEqual(masked, WELightConfig(point: 4, directional: 15, spotShadow: 1, pointShadow: 2))
    }

    /// With shadows disabled, `spotshadowcookie` is OR-ed into `spotcookie` and the shadow counts go.
    func testShadowsDisabledFoldsTheBudget() throws {
        let full = try config(#"{"spot":4,"spotshadow":1,"spotcookie":1,"spotshadowcookie":2,"pointshadow":1,"directionalshadow":1,"point":2,"directional":1}"#)
        XCTAssertEqual(full.withShadowsDisabled, WELightConfig(point: 2, spot: 4, directional: 1, spotCookie: 3))
        XCTAssertEqual(try config(#"{"spot":2,"spotcookie":1,"spotshadowcookie":1}"#).withShadowsDisabled.spotCookie, 1,
                       "a bitwise OR, not a sum")
    }

    // MARK: - general

    func testGeneralLightingAndHDRSettings() throws {
        let general = try scene().general
        let context = LightPropertyContext()
        let lighting = SceneLightingSettings(general, in: context)
        assertEqual(lighting.ambient, SIMD3(repeating: 0.3))
        assertEqual(lighting.skylight, SIMD3(repeating: 0.3))
        XCTAssertEqual(lighting.lightConfig, WELightConfig(spot: 1, spotCookie: 1))
        let bloom = SceneBloomSettings(general, in: context)
        XCTAssertTrue(bloom.enabled)
        XCTAssertTrue(bloom.hdr.enabled)
        XCTAssertEqual(bloom.hdr.strength, 0.77, accuracy: 1e-6)
        XCTAssertEqual(bloom.hdr.threshold, 1)
        XCTAssertEqual(bloom.hdr.feather, 0.18, accuracy: 1e-6)
        XCTAssertEqual(bloom.hdr.scatter, 2)
        XCTAssertEqual(bloom.hdr.iterations, 8)
    }

    /// One piece girls: bloom bound to a user property, a reddish ambient and a tube budget.
    func testUserBoundBloomAndReddishAmbient() throws {
        func bound(_ properties: [String: String] = [:]) throws -> WESceneGeneral {
            try BoundDocument.decode(WEScene.self, from: Fixtures.data("Scenes/lights/general-3270035750.json"),
                                     properties: properties).general
        }
        let general = try bound()
        XCTAssertTrue(SceneBloomSettings(general, in: LightPropertyContext()).enabled)
        XCTAssertFalse(SceneBloomSettings(try bound(["resplandorradiance": "false"]), in: LightPropertyContext()).enabled)
        XCTAssertFalse(SceneBloomSettings(general, in: LightPropertyContext()).hdr.enabled)
        assertEqual(SceneLightingSettings(general, in: LightPropertyContext()).ambient, SIMD3(0.29412, 0.13333, 0.13333))
        XCTAssertEqual(general.lightconfig, WELightConfig(tube: 4))
    }
}
