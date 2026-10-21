import XCTest
@testable import OpenWallpaperEngine

/// Decoding of value-bearing fields that may be literal or bound (`user`, `script`, `animation`).
final class SceneBindingDecodeTests: XCTestCase {
    private func loadScene() throws -> (WEScene, [String]) {
        let failures = DecodeFailureLog()
        let scene = try decodeTolerant(WEScene.self, from: Fixtures.data("Scenes/bindings/scene.json"), failures: failures)
        return (scene, failures.messages)
    }

    func testDecodesWithoutFailures() throws {
        let (scene, failures) = try loadScene()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(scene.objects.count, 3)
    }

    func testGeneralKeepsBindingsAndLiterals() throws {
        let general = try loadScene().0.general
        XCTAssertEqual(general.bloom, true)
        XCTAssertEqual(general.values[.bloom]?.userPropertyName, "bloomon")
        XCTAssertEqual(general.bloomstrength, 2)
        XCTAssertEqual(general.bloomthreshold, 0.5)
        XCTAssertEqual(general.clearcolor, "0 0 0.5")
        XCTAssertEqual(general.values[.camerashake]?.literalBool, false)
        XCTAssertEqual(general.values[.camerashakeamplitude]?.userPropertyName, "lensshakeamplitude")
        XCTAssertEqual(general.values[.camerashakespeed]?.literalDouble, 0.6)
        XCTAssertEqual(general.values[.camerashakeroughness]?.literalDouble, 1)
        XCTAssertEqual(general.values[.cameraparallax]?.userPropertyName, "parallax")
        XCTAssertEqual(general.values[.cameraparallaxamount]?.literalDouble, 0.5)
        XCTAssertEqual(general.values[.cameraparallaxdelay]?.literalDouble, 0.1)
        XCTAssertEqual(general.values[.cameraparallaxmouseinfluence]?.literalDouble, 0.4)
        XCTAssertEqual(general.ambientcolor, "0.2 0.2 0.2")
        XCTAssertEqual(general.skylightcolor, "0.3 0.3 0.3")
    }

    func testNullOrthogonalProjectionMeansPerspective() throws {
        let general = try loadScene().0.general
        XCTAssertEqual(general.projection, .perspective)

        let ortho = try JSONDecoder().decode(WEScene.self, from: Fixtures.data("Scenes/layers/scene.json")).general
        XCTAssertEqual(ortho.projection, .orthographic(width: 1920, height: 1080))
    }

    func testObjectFieldsKeepBindingsAndTypedLiterals() throws {
        let object = try loadScene().0.objects[0]
        XCTAssertEqual(object.origin, "100 200 0")
        XCTAssertEqual(object.scale, "0.2 0.2 0.2")
        XCTAssertEqual(object.color, "1 0.5 0.25")
        XCTAssertEqual(object.alpha, 1)
        XCTAssertEqual(object.brightness, 1.5)
        XCTAssertEqual(object.values[.origin]?.userPropertyName, "pos")
        XCTAssertEqual(object.values[.scale]?.userPropertyName, "size")
        XCTAssertEqual(object.values[.color]?.userPropertyName, "color")
        XCTAssertEqual(object.values[.brightness]?.userPropertyName, "brightness")
        XCTAssertEqual(object.values[.alpha], .object(.init(value: .number(1), userName: "mode", userCondition: "2")))
        XCTAssertEqual(object.values[.angles], .string("0 0 0.5"))
    }

    func testTextAndPointSizeBindings() throws {
        let text = try loadScene().0.objects[1]
        XCTAssertEqual(text.textValue, "Default caption")
        XCTAssertEqual(text.pointsize, 40)
        XCTAssertEqual(text.values[.pointsize]?.userPropertyName, "fontsize")
    }

    func testInstanceOverrideDecodesEveryField() throws {
        let override = try XCTUnwrap(loadScene().0.objects[2].instanceoverride)
        XCTAssertEqual(override.id, 7)
        XCTAssertEqual(Set(override.values.keys), [.alpha, .colorn, .count, .lifetime, .rate, .size, .speed])
        XCTAssertEqual(override.colorn, "1.000 0.500 0.250")
        XCTAssertEqual(override.size, 1.5)
        XCTAssertEqual(override.values[.size]?.userPropertyName, "flakesize")
        XCTAssertEqual(override.values[.count]?.userPropertyName, "snowamount")
        XCTAssertEqual(override.values[.rate]?.literalDouble, 0.58)
        XCTAssertEqual(override.values[.rate]?.scriptSource, "export function update(v) { return v; }")
        XCTAssertEqual(override.values[.speed]?.literalDouble, 3)
    }
}
