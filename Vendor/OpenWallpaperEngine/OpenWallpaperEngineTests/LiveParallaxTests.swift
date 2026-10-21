import XCTest
import simd
@testable import OpenWallpaperEngine

/// Parallax on or off applies from the next frame without rebuilding the content: a user property
/// bound to `general.cameraparallax…` moves the scene's binding revision only (the content
/// revision, `metalRevision`, stays), and the parallax eases in and out instead of jumping.
final class LiveParallaxTests: XCTestCase {
    private let size = SIMD2<Float>(1920, 1080)

    private func update(_ general: String, _ keys: [String]) throws -> SceneBindingUpdate {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(#"{"general": {\#(general)}, "objects": []}"#.utf8))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        return SceneBindingUpdate(keys: keys, table: table)
    }

    func testBoundParallaxDoesNotRebuildTheContent() throws {
        let toggle = try update(#""cameraparallax": {"user": "parallax", "value": false}"#, ["parallax"])
        XCTAssertEqual(toggle.impact, .none, "no content rebuild, so metalRevision stays")
        XCTAssertEqual(toggle.owners, [.scene], "the renderer resolves the camera again")
        for field in ["cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence"] {
            XCTAssertEqual(try update(#""\#(field)": {"user": "p", "value": 0.5}"#, ["p"]).impact, .none, field)
        }
        // Other scene-wide bindings are still built into the content.
        XCTAssertEqual(try update(#""bloom": {"user": "b", "value": true}"#, ["b"]).impact, .rebuildContent)
    }

    func testAppParallaxKeysDoNotRebuildTheContent() {
        XCTAssertEqual(SceneChangeImpact.aggregate(["_owe_effect_enabled_parallax", "_owe_effect_parallax_amount"]), .none)
    }

    func testParallaxEasesInOnTheNextFrame() {
        var parallax = SceneCameraParallax(sceneSize: size, enabled: false)
        parallax.update(cursor: SIMD2(1, 1), eye: .zero, sceneSize: size, influence: 1, delay: 0, deltaTime: 1 / 60)
        XCTAssertFalse(parallax.isActive)
        XCTAssertEqual(parallax.offset(rootOrigin: .zero, rootDepth: SIMD2(1, 1), amount: 1), .zero)
        XCTAssertEqual(parallax.shaderPosition(sceneSize: size), SIMD2(0.5, 0.5))

        parallax.ease(enabled: true, deltaTime: 1 / 60)
        XCTAssertTrue(parallax.isActive, "applies on the next frame")
        let first = parallax.offset(rootOrigin: .zero, rootDepth: SIMD2(1, 1), amount: 1)
        let full = -size
        XCTAssertLessThan(simd_length(first), simd_length(full), "eases in rather than jumping")
        XCTAssertGreaterThan(simd_length(first), 0)

        for _ in 0..<120 { parallax.ease(enabled: true, deltaTime: 1 / 60) }
        XCTAssertEqual(parallax.weight, 1, "fully on is WE's parallax exactly")
        XCTAssertEqual(parallax.offset(rootOrigin: .zero, rootDepth: SIMD2(1, 1), amount: 1), full)
        XCTAssertEqual(parallax.shaderPosition(sceneSize: size), SIMD2(1, 1))
    }

    func testParallaxEasesOutAndStops() {
        var parallax = SceneCameraParallax(sceneSize: size)
        parallax.update(cursor: SIMD2(1, 1), eye: .zero, sceneSize: size, influence: 1, delay: 0, deltaTime: 1 / 60)
        parallax.ease(enabled: false, deltaTime: 1 / 60)
        XCTAssertTrue(parallax.isActive)
        XCTAssertGreaterThan(parallax.weight, 0.5, "eases out rather than snapping back")
        for _ in 0..<120 { parallax.ease(enabled: false, deltaTime: 1 / 60) }
        XCTAssertFalse(parallax.isActive, "stops once eased out")
        XCTAssertEqual(parallax.offset(rootOrigin: .zero, rootDepth: SIMD2(1, 1), amount: 1), .zero)
    }
}
