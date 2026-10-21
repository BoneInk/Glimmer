import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The HDR fixture (`bloom` and `hdr` on, WE's HDR defaults; an overbright square, 0.8 at
/// brightness 2, and a 0.85 one, on black) drawn by the real renderer under each post-processing
/// setting: HDR only with "ultra" (and "displayhdr", which draws as "ultra" without an HDR
/// output), float targets, WE's HDR chain on the finished frame, and the LDR path otherwise.
final class SceneHDRRenderTests: XCTestCase {
    private static let size = SIMD2(480, 272)
    /// Drawable pixels (y down): the squares' centres and a point 8 px right of each.
    private static let bright = (center: SIMD2(320, 136), outside: SIMD2(360, 136))
    private static let dim = (center: SIMD2(120, 136), outside: SIMD2(160, 136))

    private var directory: URL!

    override func setUpWithError() throws {
        directory = Fixtures.url("Scenes/hdr")
    }

    override func tearDownWithError() throws {
        if let directory { Fixtures.removeStoredSettings(for: directory) }
    }

    /// The settings gate: HDR at load only for `bloom` and `hdr` with "ultra" or "displayhdr".
    func testHDROnlyWithUltra() throws {
        _ = try Fixtures.assets()
        for (quality, hdr) in [(GSPostProcessingQuality.ultra, true), (.displayhdr, true), (.enabled, false), (.disabled, false)] {
            let content = try content(quality)
            XCTAssertEqual(content.engineCombos.hdr, hdr, "\(quality)")
            XCTAssertEqual(content.hdrChain != nil, hdr, "\(quality): the HDR chain is planned only in HDR")
            XCTAssertEqual(content.bloomChain != nil, !hdr, "\(quality): the LDR chain is planned only outside HDR")
        }
    }

    /// Ultra: the scene draws into RGBA16F with overbright kept, WE's HDR chain blooms only what
    /// passes its threshold of 1, and the result equals the CPU model on the frame.
    func testUltraBloomsOnlyTheOverbright() throws {
        _ = try Fixtures.assets()
        let (pixels, renderer) = try render(.ultra)
        defer { renderer.releaseContent() }
        let post = renderer.postProcess
        XCTAssertTrue(post.drawsHDR)
        XCTAssertNil(post.lastBloom, "no LDR bloom in HDR")
        let record = try XCTUnwrap(post.lastHDR, "WE's HDR chain didn't run")
        XCTAssertEqual(record.frame.pixelFormat, .rgba16Float)
        XCTAssertEqual(record.levels, 8)
        XCTAssertEqual(record.constants, SceneHDRChain.Constants(SceneHDRBloomSettings(), levels: 8, tint: SIMD3(repeating: 1)))

        let frame = try HDRReference.read(record.frame, device: record.frame.device)
        let center = SIMD2(Int(Float(frame.width) * 320 / 480), frame.height / 2)
        XCTAssertEqual(frame[center.x, center.y].x, 1.6, accuracy: 0.01, "the float frame keeps the overbright value")

        XCTAssertEqual(pixels.rgb(Self.bright.center), SIMD3(repeating: 255))
        XCTAssertGreaterThan(pixels.rgb(Self.bright.outside).x, 20, "the overbright square glows")

        let expected = HDRReference.run(frame, levels: 8, constants: record.constants)
        let output = try TextureUploadTests.read(record.combined, device: record.frame.device)
        let worst = zip(output, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, 2, "off the CPU model by \(worst)/255")

        // Eight levels spread the overbright square's glow over the whole frame, the 0.85 square
        // included; the 0.85 square is below the knee (0.9) and adds none of its own: the frame
        // blooms the same without it.
        var withoutDim = frame
        for index in withoutDim.pixels.indices where abs(withoutDim.pixels[index].x - 0.85) < 0.01 {
            withoutDim.pixels[index] = .zero
        }
        let bloom = HDRReference.levels(withoutDim, levels: 8, constants: record.constants)[0]
        let dimOutside = SIMD2(Int(Float(frame.width) * 160 / 480), frame.height / 2)
        let glow = HDRReference.combined(frame, bloom: bloom, x: dimOutside.x, y: dimOutside.y)
        let drawn = (dimOutside.y * frame.width + dimOutside.x) * 4
        XCTAssertLessThanOrEqual(abs(Int(output[drawn]) - Int(glow.x)), 2, "the 0.85 square adds no glow")
        XCTAssertGreaterThan(output[drawn], 0, "the overbright square's glow reaches it")
    }

    /// `bloomhdr*` are live, as WE recomputes the chain's constants whenever the scene changes
    /// (0x140184020): a timeline holding `bloomhdrstrength` at 0 (the authored value is 2) drives
    /// the chain's strength, and nothing blooms.
    func testATimelineOnBloomHDRStrengthDrivesTheChain() throws {
        _ = try Fixtures.assets()
        directory = Fixtures.url("Scenes/hdr-animated")
        let (pixels, renderer) = try render(.ultra)
        defer { renderer.releaseContent() }
        let record = try XCTUnwrap(renderer.postProcess.lastHDR, "WE's HDR chain didn't run")
        XCTAssertEqual(record.constants.strength, 0, "the timeline's strength, not the authored 2")
        XCTAssertLessThanOrEqual(pixels.rgb(Self.bright.outside).x, 1, "nothing blooms")
    }

    /// LF7: the HDR combine's output (and the last frame's records) don't outlive the HDR content:
    /// the same renderer given the LDR content holds none of them.
    func testTheHDROutputGoesWithTheHDRContent() throws {
        _ = try Fixtures.assets()
        let (_, renderer) = try render(.ultra)
        defer { renderer.releaseContent() }
        XCTAssertTrue(renderer.postProcess.holdsHDROutput)
        renderer.setContent(try content(.enabled))
        let deadline = Date().addingTimeInterval(30)
        while renderer.postProcess.drawsHDR, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(renderer.postProcess.drawsHDR)
        XCTAssertFalse(renderer.postProcess.holdsHDROutput)
        XCTAssertNil(renderer.postProcess.lastHDR)
    }

    /// "displayhdr" without an HDR output draws as "ultra" (WE's fallback, 0x1401109be).
    func testDisplayHDRDrawsAsUltra() throws {
        _ = try Fixtures.assets()
        let (ultra, first) = try render(.ultra)
        first.releaseContent()
        let (display, second) = try render(.displayhdr)
        defer { second.releaseContent() }
        XCTAssertNotNil(second.postProcess.lastHDR)
        XCTAssertEqual(display.bytes, ultra.bytes)
    }

    /// "enabled" is LDR: an 8-bit scene target (the overbright square clamps to white), and WE's
    /// LDR bloom, which blooms both squares (0.85 is above its threshold of 0.65).
    func testEnabledStaysLDR() throws {
        _ = try Fixtures.assets()
        let (pixels, renderer) = try render(.enabled)
        defer { renderer.releaseContent() }
        XCTAssertFalse(renderer.postProcess.drawsHDR)
        XCTAssertNil(renderer.postProcess.lastHDR)
        let bloom = try XCTUnwrap(renderer.postProcess.lastBloom, "WE's LDR bloom didn't run")
        XCTAssertNotEqual(bloom.frame.pixelFormat, .rgba16Float)
        XCTAssertEqual(pixels.rgb(Self.bright.center), SIMD3(repeating: 255))
        XCTAssertGreaterThan(pixels.rgb(Self.dim.outside).x, 0, "LDR bloom takes 0.85")
    }

    // MARK: - Helpers

    private struct Pixels {
        let bytes: [UInt8]

        /// (r, g, b) at a drawable pixel.
        func rgb(_ point: SIMD2<Int>) -> SIMD3<UInt8> {
            let i = (point.y * SceneHDRRenderTests.size.x + point.x) * 4
            return SIMD3(bytes[i + 2], bytes[i + 1], bytes[i])
        }
    }

    private func content(_ postProcessing: GSPostProcessingQuality) throws -> SceneMetalContent {
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent())
    }

    /// Draws the fixture with `postProcessing` until its chain has run; the last frame's drawable.
    private func render(_ postProcessing: GSPostProcessingQuality) throws -> (Pixels, SceneMetalRenderer) {
        let content = try content(postProcessing)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "hdr"))
        view.isPaused = true
        renderer.renderSettings.postProcessing = postProcessing
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        let post = renderer.postProcess
        var drawn = 0
        let deadline = Date().addingTimeInterval(30)
        func ran() -> Bool { post.drawsHDR ? post.lastHDR != nil : (!content.bloom.enabled || post.lastBloom != nil) }
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if renderer.hasContent { drawn += 1 }
        } while (drawn < 3 || (postProcessing != .disabled && !ran())) && Date() < deadline
        // `currentDrawable` hands out the view's drawables in turn: draw until each holds a settled
        // frame, or the one read below can be an early frame's.
        for _ in 0..<4 {
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        var bytes = [UInt8](repeating: 0, count: Self.size.x * Self.size.y * 4)
        view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: Self.size.x * 4,
                                               from: MTLRegionMake2D(0, 0, Self.size.x, Self.size.y), mipmapLevel: 0)
        return (Pixels(bytes: bytes), renderer)
    }
}
