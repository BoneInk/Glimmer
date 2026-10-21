import XCTest
@testable import OpenWallpaperEngine

private struct PropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    func userProperty(_ name: String) -> String? { properties[name] }
}

/// Bound values follow the user properties they're bound to.
final class SceneBindingResolutionTests: XCTestCase {
    private func loadScene() throws -> WEScene {
        try decodeTolerant(WEScene.self, from: Fixtures.data("Scenes/bindings/scene.json"))
    }

    /// The scene as the loader decodes it with `properties` (`UserPropertyBindingTable`).
    private func resolvedScene(_ properties: [String: String] = [:]) throws -> WEScene {
        let document = try decodeTolerant(SceneJSON.self, from: Fixtures.data("Scenes/bindings/scene.json"))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        return try table.resolvedScene(loadScene(), document: document, properties: { properties[$0] })
    }

    func testObjectFieldsFollowTheirProperties() throws {
        let resolved = try resolvedScene(["pos": "300 400 0", "size": "0.5", "color": "0 1 0",
                                          "mode": "2", "brightness": "0.25"]).objects[0]
        XCTAssertEqual(resolved.origin, "300 400 0")
        XCTAssertEqual(resolved.scale, "0.5 0.5 0.5", "a scalar slider scales every axis")
        XCTAssertEqual(resolved.color, "0 1 0")
        XCTAssertEqual(resolved.alpha, 1, "condition '2' matches")
        XCTAssertEqual(resolved.brightness, 0.25)
        XCTAssertEqual(resolved.angles, "0 0 0.5", "unbound fields keep their literal")

        let hidden = try resolvedScene(["mode": "1"]).objects[0]
        XCTAssertEqual(hidden.alpha, 0, "condition '2' doesn't match")
        XCTAssertEqual(hidden.color, "1 0.5 0.25", "missing properties keep the literal")
    }

    /// User-bound `scriptproperties` are the SceneScript runtime's (`SceneScriptSiteBuilder`).
    func testTextAndPointSize() throws {
        let resolved = try resolvedScene(["caption": "Hello there", "fontsize": "64", "ylensy": "0.7"]).objects[1]
        XCTAssertEqual(resolved.textValue, "Hello there")
        XCTAssertEqual(resolved.pointsize, 64)
        XCTAssertEqual(try resolvedScene().objects[1].textValue, "Default caption")
    }

    func testLayerBindingsApplyChangesSinceBuild() throws {
        let object = try loadScene().objects[0]
        let built = PropertyContext(properties: ["pos": "100 200 0", "size": "0.2", "color": "1 0.5 0.25",
                                                 "mode": "2", "brightness": "1.5"])
        let bindings = SceneLayerBindings(object: object, builtWith: built)
        // A layer as built: its position includes a parent offset of (10, 10).
        let layer = SceneMetalLayer(id: "1", name: "Tinted", source: .image(NSImage()), position: SIMD2(110, 210),
                                    size: SIMD2(200, 200), scale: SIMD2(0.2, 0.2),
                                    opacity: 1, brightness: 1.5, color: SIMD4(1, 0.5, 0.25, 1), text: nil, parallaxDepth: .zero,
                                    perspective: false, rotation: 0.5)
        XCTAssertEqual(bindings.baseValues(for: layer, in: built), SceneLayerBaseValues(layer))

        var changed = built
        changed.properties.merge(["pos": "150 200 0", "size": "0.4", "color": "0.5 0.5 0.5", "mode": "0",
                                  "brightness": "0.75"]) { $1 }
        let base = bindings.baseValues(for: layer, in: changed)
        XCTAssertEqual(base.position, SIMD2(160, 210), "origin moves by the change, keeping the parent offset")
        XCTAssertEqual(base.scale.x, 0.4, accuracy: 1e-5)
        XCTAssertEqual(base.color.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(base.color.z, 0.5, accuracy: 1e-5)
        XCTAssertEqual(base.opacity, 0)
        XCTAssertEqual(base.brightness, 0.75, accuracy: 1e-5)
        XCTAssertEqual(base.rotation, 0.5, "angles isn't bound")
    }

    /// A channel that is 0 at build has no ratio; with no rebuild it must still follow the property.
    func testZeroChannelAtBuildStillUpdatesLive() throws {
        let object = try loadScene().objects[0]
        let built = PropertyContext(properties: ["color": "0 1 1", "mode": "1"])
        let bindings = SceneLayerBindings(object: object, builtWith: built)
        let layer = SceneMetalLayer(id: "1", name: "Tinted", source: .image(NSImage()), position: .zero,
                                    size: SIMD2(200, 200), scale: SIMD2(1, 1),
                                    opacity: 0, brightness: 1, color: SIMD4(0, 1, 1, 1), text: nil, parallaxDepth: .zero,
                                    perspective: false, rotation: 0)
        let base = bindings.baseValues(for: layer, in: PropertyContext(properties: ["color": "0.6 1 1", "mode": "2"]))
        XCTAssertEqual(base.color.x, 0.6, accuracy: 1e-5)
        XCTAssertEqual(base.opacity, 1, accuracy: 1e-5)
    }

    func testParticleOverridesResolveBindings() throws {
        let object = try loadScene().objects[2]
        let defaults = SceneParticleOverrides(object.instanceoverride, in: PropertyContext())
        XCTAssertEqual(defaults.rate, 0.58, accuracy: 1e-5)
        XCTAssertEqual(defaults.count, 0.1, accuracy: 1e-5)
        XCTAssertEqual(defaults.size, 1.5)
        XCTAssertEqual(defaults.alpha, 0.5)
        XCTAssertEqual(defaults.lifetime, 2)
        XCTAssertEqual(defaults.speed, 3)
        XCTAssertEqual(defaults.tint, SIMD3(1, 0.5, 0.25))

        let bound = SceneParticleOverrides(object.instanceoverride,
                                           in: PropertyContext(properties: ["snowamount": "0.8", "flakesize": "2"]))
        XCTAssertEqual(bound.count, 0.8, accuracy: 1e-5)
        XCTAssertEqual(bound.size, 2)
        XCTAssertEqual(SceneParticleOverrides(nil, in: PropertyContext()), SceneParticleOverrides())
    }

    func testGeneralBloomAndCameraFollowProperties() throws {
        func general(_ properties: [String: String]) throws -> WESceneGeneral { try resolvedScene(properties).general }
        let off = SceneBloomSettings(try general(["bloomon": "false"]), in: PropertyContext())
        XCTAssertFalse(off.enabled)
        let on = SceneBloomSettings(try general(["bloomcut": "0.9"]), in: PropertyContext())
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.strength, 2)
        XCTAssertEqual(on.threshold, 0.9, accuracy: 1e-5)

        let camera = SceneCameraEffects(try general(["lensshake": "true", "parallax": "1"]), in: PropertyContext())
        XCTAssertTrue(camera.shake)
        XCTAssertEqual(camera.shakeAmplitude, 3)
        XCTAssertEqual(camera.shakeSpeed, 0.6, accuracy: 1e-5)
        XCTAssertTrue(camera.parallax)
        XCTAssertEqual(camera.parallaxMouseInfluence, 0.4, accuracy: 1e-5)
        XCTAssertFalse(SceneCameraEffects(try general([:]), in: PropertyContext()).shake)
    }

    /// R2: 3378346807 binds `clearcolor` to its `backgroundcolor` property; WE's capture shows the
    /// empty scene as (65,80,83), the property exactly. An unauthored clear colour is black.
    func testClearColorFollowsItsProperty() throws {
        let json = #"{"general": {"clearcolor": {"user": "backgroundcolor", "value": "0.25490 0.31373 0.32549"}}}"#
        let document = try decodeTolerant(SceneJSON.self, from: Data(json.utf8))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        func general(_ properties: [String: String]) throws -> WESceneGeneral {
            let resolved = table.resolvedDocument(document, document: .scene, properties: { properties[$0] })
            guard case .object(let root) = resolved, let general = root["general"] else { throw CocoaError(.coderReadCorrupt) }
            return try UserPropertyBindingTable.decode(WESceneGeneral.self, from: general)
        }
        let bound = try general(["backgroundcolor": "0.2549019607843137 0.3137254901960784 0.3254901960784314"]).clearColor(in: PropertyContext())
        XCTAssertEqual(bound.x * 255, 65, accuracy: 0.01)
        XCTAssertEqual(bound.y * 255, 80, accuracy: 0.01)
        XCTAssertEqual(bound.z * 255, 83, accuracy: 0.01)
        let changed = try general(["backgroundcolor": "1 0 0"]).clearColor(in: PropertyContext())
        XCTAssertEqual(changed, SIMD3(1, 0, 0))
        let unauthored = try decodeTolerant(WESceneGeneral.self, from: Data("{}".utf8))
        XCTAssertEqual(unauthored.clearColor(in: PropertyContext()), .zero)
    }
}
