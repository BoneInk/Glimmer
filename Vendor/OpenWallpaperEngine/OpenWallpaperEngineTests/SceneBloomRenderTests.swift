import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The bloom fixture (a white and a 0.6 grey square on black, `bloom` on with WE's defaults) drawn
/// by the real renderer: WE's chain runs once on the finished frame, before the composite puts it
/// on the drawable, and only when the post-processing setting allows it.
final class SceneBloomRenderTests: XCTestCase {
    private static let size = SIMD2(480, 272)
    /// Drawable pixels (y down): the squares' centres and a point 4 px right of each.
    private static let bright = (center: SIMD2(320, 136), outside: SIMD2(356, 136))
    private static let dim = (center: SIMD2(120, 136), outside: SIMD2(156, 136))

    private var directory: URL!

    override func setUpWithError() throws {
        directory = Fixtures.url("Scenes/bloom")
    }

    override func tearDownWithError() throws {
        if let directory { Fixtures.removeStoredSettings(for: directory) }
    }

    func testBloomGlowsAroundWhatPassesTheThreshold() throws {
        _ = try Fixtures.assets()
        let (pixels, record) = try render(.enabled)
        let bloom = try XCTUnwrap(record, "WE's bloom didn't run")
        XCTAssertEqual(bloom.strength, 2)
        XCTAssertEqual(bloom.threshold, 0.65, accuracy: 1e-6)
        XCTAssertEqual(pixels.rgb(Self.bright.center), SIMD3(repeating: 255))
        XCTAssertGreaterThan(pixels.rgb(Self.bright.outside).x, 40, "the white square glows")
        XCTAssertEqual(pixels.rgb(Self.dim.center), SIMD3(repeating: 153), "0.6 is below the threshold")
        XCTAssertEqual(pixels.rgb(Self.dim.outside), .zero, "nothing glows around it")

        // The chain ran on the scene target and matches the CPU model.
        let device = bloom.frame.device
        let input = try TextureUploadTests.read(bloom.frame, device: device)
        let output = try TextureUploadTests.read(bloom.bloomed, device: device)
        let expected = BloomReference.run(BloomReference.Image(bytes: input, width: bloom.frame.width, height: bloom.frame.height),
                                          strength: bloom.strength, threshold: bloom.threshold, tint: bloom.tint).rgba
        let worst = zip(output, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 2)
    }

    /// Post-processing "disabled" turns WE's bloom off (render flag 0x40).
    func testNoBloomWithPostProcessingDisabled() throws {
        _ = try Fixtures.assets()
        let (pixels, record) = try render(.disabled)
        XCTAssertNil(record)
        XCTAssertEqual(pixels.rgb(Self.bright.center), SIMD3(repeating: 255))
        XCTAssertEqual(pixels.rgb(Self.bright.outside), .zero)
    }

    // MARK: - Helpers

    private struct Pixels {
        let bytes: [UInt8]

        /// (r, g, b) at a drawable pixel.
        func rgb(_ point: SIMD2<Int>) -> SIMD3<UInt8> {
            let i = (point.y * SceneBloomRenderTests.size.x + point.x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
    }

    /// Draws the fixture with `postProcessing` until its pipelines are ready; the last frame's
    /// drawable and bloom.
    private func render(_ postProcessing: GSPostProcessingQuality) throws -> (Pixels, ScenePostProcess.BloomRecord?) {
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/bloom/project.json"))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        XCTAssertNotNil(content.bloomChain)
        XCTAssertTrue(content.bloom.enabled)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "bloom"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings.postProcessing = postProcessing
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var drawn = 0
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if renderer.hasContent { drawn += 1 }
        } while (drawn < 3 || (postProcessing != .disabled && renderer.postProcess.lastBloom == nil)) && Date() < deadline
        var bytes = [UInt8](repeating: 0, count: Self.size.x * Self.size.y * 4)
        view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: Self.size.x * 4,
                                               from: MTLRegionMake2D(0, 0, Self.size.x, Self.size.y), mipmapLevel: 0)
        return (Pixels(bytes: bytes), renderer.postProcess.lastBloom)
    }
}
