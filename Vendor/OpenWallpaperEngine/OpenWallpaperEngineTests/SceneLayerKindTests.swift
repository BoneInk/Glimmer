import XCTest
@testable import OpenWallpaperEngine

/// Loader checks for layer kinds that need more than an image: solid layers, text with effects,
/// and the scene.json draw order across layers and particle systems.
final class SceneLayerKindTests: XCTestCase {
    private func content(_ fixture: String) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/\(fixture)")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
        let wallpaper = WEWallpaper(using: project, where: directory)
        addTeardownBlock {
            Fixtures.removeStoredSettings(for: directory)
        }
        return try XCTUnwrap(SceneContentLoader(wallpaper: wallpaper).metalContent())
    }

    /// The colour of the generated solid texture, read back through a known RGBA8 context.
    private func solidColor(_ layer: SceneMetalLayer) throws -> SIMD4<Float> {
        guard case let .image(image) = layer.source else {
            XCTFail("solid layer \(layer.id) has no generated image")
            return .zero
        }
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SIMD4<Float>(pixel.map { Float($0) / 255 })
    }

    /// D7: text is no longer lifted above later layers, and particles sit between layers by object index.
    func testLayersAndParticlesKeepSceneOrder() throws {
        _ = try Fixtures.assets()
        let content = try content("ordering")
        XCTAssertEqual(content.layers.map(\.id), ["10", "20", "40"], "layers must keep scene.json order")
        XCTAssertEqual(content.layers.map(\.order), [0, 1, 3])
        XCTAssertEqual(content.particleSystems.map(\.order), [2])
        let shade = try XCTUnwrap(content.layers.last)
        XCTAssertEqual(shade.opacity, 0.5)
        XCTAssertEqual(shade.size, SIMD2(1920, 1080))
    }

    func testTextLayersKeepTheirAuthoredEffects() throws {
        try XCTSkipUnless(Fixtures.hasWEShaderSources, "WE shader sources or toolchain unavailable")
        let text = try XCTUnwrap(try content("ordering").layers.first { $0.id == "10" })
        XCTAssertNotNil(text.text)
        XCTAssertEqual(text.weEffects.count, 1, "B2: text layers must run their effects")
    }

    func testSolidLayersRenderTheirColourAtTheirSize() throws {
        _ = try Fixtures.assets()
        let layers = Dictionary(uniqueKeysWithValues: try content("solid").layers.map { ($0.id, $0) })
        XCTAssertEqual(Set(layers.keys), ["1", "2", "3"])

        // 3352730400 'Album Border': no color (white), alpha 0.33, 100x100 scaled by 56.
        let border = try XCTUnwrap(layers["1"])
        XCTAssertEqual(border.size, SIMD2(100, 100))
        XCTAssertEqual(border.scale, SIMD2(56, 56))
        XCTAssertEqual(border.opacity, 0.33, accuracy: 0.0001)
        let white = try solidColor(border)
        XCTAssertEqual(white.x, 1, accuracy: 0.01)
        XCTAssertEqual(white.y, 1, accuracy: 0.01)
        XCTAssertEqual(white.z, 1, accuracy: 0.01)
        XCTAssertEqual(white.w, 1, accuracy: 0.01)

        // A zero size stays zero: the layer is kept (its scripts run) but its quad is empty, as in WE.
        // The colour is baked into the texture, not doubled on the quad.
        let tinted = try XCTUnwrap(layers["2"])
        XCTAssertEqual(tinted.size, .zero)
        XCTAssertEqual(tinted.color, SIMD4(repeating: 1))
        let red = try solidColor(tinted)
        XCTAssertEqual(red.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(red.y, 0.2, accuracy: 0.01)
        XCTAssertEqual(red.z, 0.2, accuracy: 0.01)

        let unsized = try XCTUnwrap(layers["3"])
        XCTAssertEqual(unsized.size, SIMD2(1920, 1080))
        let green = try solidColor(unsized)
        XCTAssertEqual(green.x, 0, accuracy: 0.01)
        XCTAssertEqual(green.y, 1, accuracy: 0.01)
    }

    /// WE's objects default `parallaxDepth` to 1 1 and its writer leaves defaults out: a layer
    /// without the key moves with camera parallax; an authored depth, even 0 0, is kept.
    func testAbsentParallaxDepthIsWEsDefault() throws {
        _ = try Fixtures.assets()
        let layers = Dictionary(uniqueKeysWithValues: try content("parallax-depth").layers.map { ($0.id, $0) })
        XCTAssertEqual(layers["1"]?.parallaxDepth, SIMD3(1, 1, 0))
        XCTAssertEqual(layers["2"]?.parallaxDepth, SIMD3(0, 0, 0))
        XCTAssertEqual(layers["3"]?.parallaxDepth, SIMD3(0, 0.5, 0))
        // Text reads its object's depth like any layer; it used to be pinned at 0 0.
        XCTAssertEqual(layers["4"]?.parallaxDepth, SIMD3(1, 1, 0))
        XCTAssertEqual(layers["5"]?.parallaxDepth, SIMD3(0.25, 0.75, 0))
    }
}
