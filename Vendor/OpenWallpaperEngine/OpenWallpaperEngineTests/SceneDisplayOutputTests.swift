import XCTest
import MetalKit
import simd
import UniformTypeIdentifiers
@testable import OpenWallpaperEngine

/// WE's display HDR on macOS's EDR (docs/lighting-plan.md §2.6 "Display HDR", `SceneDisplayOutput`):
/// which output a frame takes, how a view is set up for it, the chain's display HDR combine, and
/// the HDR fixture (`Scenes/hdr`: an overbright square, 0.8 at brightness 2, and a 0.85 one) drawn
/// by the real renderer onto a view whose screen reports EDR headroom.
final class SceneDisplayOutputTests: XCTestCase {
    private static let size = SIMD2(480, 272)
    /// The overbright square's centre, in drawable pixels (y down).
    private static let bright = SIMD2(320, 136)
    private static let edr = SceneDisplayHeadroom(potential: 4, current: 4)

    override func tearDownWithError() throws {
        Fixtures.removeStoredSettings(for: Fixtures.url("Scenes/hdr"))
    }

    // MARK: - Selection

    /// EDR only for a content drawn in HDR under "displayhdr" on a display with headroom; every
    /// other case keeps the standard output (WE drops display HDR without an HDR monitor,
    /// 0x1401109be, and "ultra" never has it).
    func testEDROnlyForDisplayHDROnAScreenWithHeadroom() {
        let none = SceneDisplayHeadroom()
        for quality in [GSPostProcessingQuality.disabled, .enabled, .ultra, .displayhdr] {
            for drawsHDR in [false, true] {
                for headroom in [none, Self.edr, SceneDisplayHeadroom(potential: 1, current: 1)] {
                    let output = SceneDisplayOutput.select(postProcessing: quality, drawsHDR: drawsHDR, headroom: headroom)
                    let extended = quality == .displayhdr && drawsHDR && headroom.potential > 1
                    XCTAssertEqual(output.isExtended, extended, "\(quality), HDR \(drawsHDR), \(headroom)")
                }
            }
        }
        // The potential decides; RV follows the headroom the screen shows now (it can be 1 while
        // the display ramps up), never below SDR white.
        let ramping = SceneDisplayOutput.select(postProcessing: .displayhdr, drawsHDR: true,
                                                headroom: SceneDisplayHeadroom(potential: 16, current: 1))
        XCTAssertEqual(ramping, .extendedRange(headroom: 1))
        XCTAssertEqual(ramping.renderVar, SIMD2(1, 0))
        XCTAssertEqual(SceneDisplayOutput.extendedRange(headroom: 2.5).renderVar, SIMD2(1, 1.5))
        XCTAssertEqual(SceneDisplayOutput.extendedRange(headroom: 0.5).renderVar, SIMD2(1, 0))
        XCTAssertNil(SceneDisplayOutput.standard.renderVar)
    }

    /// The EDR drawable: `rgba16Float` in extended linear sRGB with EDR requested; the standard
    /// output restores a view it had set up and leaves any other view as it is.
    func testTheViewIsSetUpForEDRAndBack() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.colorPixelFormat = .bgra8Unorm
        let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
        let initial = layer.colorspace?.name
        XCTAssertEqual(initial, SceneDisplayOutput.standardColorSpace?.name, "MTKView's own colour space")
        SceneDisplayOutput.standard.apply(to: view, standard: .bgra8Unorm)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.colorspace?.name, initial, "a view that never showed EDR is left alone")

        SceneDisplayOutput.extendedRange(headroom: 4).apply(to: view, standard: .bgra8Unorm)
        XCTAssertEqual(view.colorPixelFormat, .rgba16Float)
        XCTAssertEqual(layer.pixelFormat, .rgba16Float)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.colorspace?.name, CGColorSpace.extendedLinearSRGB)

        SceneDisplayOutput.standard.apply(to: view, standard: .bgra8Unorm)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
        XCTAssertEqual(layer.colorspace?.name, initial)
    }

    // MARK: - The chain

    /// With display HDR the chain ends in `combine_dhdr_upsample` (0x14017fb49) with display HDR's
    /// RV; without, in `combine_hdr_upsample` with (1, 0); `combine_srgb` alone either way.
    func testTheChainCombinesWithTheDisplayHDRPass() {
        let chainIndices = { (levels: Int?, display: Bool) -> [Int] in
            SceneHDRChain.renderVars(levels: levels ?? 1, size: SIMD2(64, 64), displayHDR: display ? SIMD2(1, 3) : nil)
                .keys.sorted()
        }
        XCTAssertTrue(chainIndices(4, true).contains(SceneHDRChain.Pass.combineDisplayHDR))
        XCTAssertFalse(chainIndices(4, true).contains(SceneHDRChain.Pass.combine))
        XCTAssertTrue(chainIndices(4, false).contains(SceneHDRChain.Pass.combine))
        let vars = SceneHDRChain.renderVars(levels: 4, size: SIMD2(64, 64), displayHDR: SIMD2(1, 3))
        XCTAssertEqual(vars[SceneHDRChain.Pass.combineDisplayHDR]?.x, 1)
        XCTAssertEqual(vars[SceneHDRChain.Pass.combineDisplayHDR]?.y, 3)
        XCTAssertEqual(SceneHDRChain.renderVars(levels: 4, size: SIMD2(64, 64))[SceneHDRChain.Pass.combine]?.y, 0)
        XCTAssertTrue(SceneHDRChain.effectDocument.contains("materials/util/combine_dhdr_upsample.json"))
    }

    // MARK: - Through the renderer

    /// "displayhdr" on a screen with headroom 4: the drawable is `rgba16Float` in extended linear
    /// sRGB, the combine is WE's display HDR one with RV (1, 3), its output equals a CPU model of
    /// `combine_hdr`'s `DISPLAYHDR` branch on the float frame, and values above 1 reach the
    /// drawable where the overbright square blooms; the rest of the frame stays at SDR levels.
    func testDisplayHDRPutsValuesAboveOneOnTheDrawable() throws {
        _ = try Fixtures.assets()
        let (view, renderer) = try render(.displayhdr, headroom: Self.edr)
        defer { renderer.releaseContent() }
        XCTAssertEqual(renderer.displayOutput, .extendedRange(headroom: 4))
        XCTAssertEqual(view.colorPixelFormat, .rgba16Float)
        XCTAssertEqual((view.layer as? CAMetalLayer)?.colorspace?.name, CGColorSpace.extendedLinearSRGB)
        let record = try XCTUnwrap(renderer.postProcess.lastHDR, "WE's HDR chain didn't run")
        XCTAssertEqual(record.combined.pixelFormat, .rgba16Float)
        let device = record.frame.device
        let frame = try HDRReference.read(record.frame, device: device)
        let combined = try HDRReference.read(record.combined, device: device)
        let bloom = HDRReference.levels(frame, levels: try XCTUnwrap(record.levels), constants: record.constants)[0]
        var worst: Float = 0
        for y in stride(from: 0, to: frame.height, by: 3) {
            for x in stride(from: 0, to: frame.width, by: 3) {
                let expected = Self.displayCombined(frame, bloom: bloom, x: x, y: y, renderVar: SIMD2(1, 3))
                let error = simd_reduce_max(abs(combined[x, y] - expected) / simd_max(expected, SIMD3(repeating: 0.25)))
                worst = max(worst, error)
            }
        }
        XCTAssertLessThan(worst, 0.02, "off the CPU model of DISPLAYHDR by \(worst) (relative)")

        let drawn = try HDRReference.read(try XCTUnwrap(view.currentDrawable?.texture), device: device)
        try Self.write(drawn, name: "displayhdr-drawable-over-4")
        let peak = drawn[Self.bright.x, Self.bright.y]
        // WE caps nothing at the display's maximum: RV.y scales the bloomed luma's excess, and the
        // display clips what lies past its headroom.
        XCTAssertGreaterThan(peak.x, 1.05, "the overbright square's bloom goes above SDR white: \(peak)")
        XCTAssertEqual(peak.x, combined[Self.bright.x * combined.width / Self.size.x,
                                        Self.bright.y * combined.height / Self.size.y].x, accuracy: 0.05,
                       "the drawable shows the combine as it is")
        XCTAssertEqual(drawn[4, 4].x, 0, accuracy: 0.01, "black stays black")
    }

    /// "ultra" is unchanged by a screen with headroom: the same bytes on the same `bgra8Unorm`
    /// drawable, and the standard combine.
    func testUltraIsTheSameWithOrWithoutHeadroom() throws {
        _ = try Fixtures.assets()
        let (plainView, plain) = try render(.ultra, headroom: SceneDisplayHeadroom())
        let plainBytes = try Self.bytes(plainView)
        plain.releaseContent()
        let (view, renderer) = try render(.ultra, headroom: Self.edr)
        defer { renderer.releaseContent() }
        XCTAssertEqual(renderer.displayOutput, .standard)
        XCTAssertEqual(view.colorPixelFormat, .bgra8Unorm)
        XCTAssertFalse((view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent ?? true)
        XCTAssertEqual(renderer.postProcess.lastHDR?.combined.pixelFormat, SceneHDRChain.outputFormat)
        XCTAssertEqual(try Self.bytes(view), plainBytes)
    }

    /// "displayhdr" without headroom draws exactly as "ultra" (WE's fallback, 0x1401109be).
    func testDisplayHDRWithoutHeadroomDrawsAsUltra() throws {
        _ = try Fixtures.assets()
        let (ultraView, ultra) = try render(.ultra, headroom: SceneDisplayHeadroom())
        let ultraBytes = try Self.bytes(ultraView)
        ultra.releaseContent()
        let (view, renderer) = try render(.displayhdr, headroom: SceneDisplayHeadroom())
        defer { renderer.releaseContent() }
        XCTAssertEqual(renderer.displayOutput, .standard)
        XCTAssertEqual(try Self.bytes(view), ultraBytes)
    }

    /// A shared frame (several displays) is drawn in EDR once the views it is shown on have
    /// headroom, and each view is set up to show it.
    func testASharedFrameFollowsTheViewsItIsShownOn() throws {
        _ = try Fixtures.assets()
        let content = try Self.content(.displayhdr)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = Self.view(device: device)
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: nil, screenID: "edr-shared"))
        defer { renderer.releaseContent() }
        renderer.configure(view)
        view.isPaused = true
        renderer.displayHeadroom = { _ in Self.edr }
        renderer.renderSettings.postProcessing = .displayhdr
        renderer.setContent(content)
        let viewport = SceneViewport(drawableSize: SIMD2(Float(Self.size.x), Float(Self.size.y)),
                                     pointSize: SIMD2(Float(Self.size.x), Float(Self.size.y)), cursor: nil, frameRateLimit: 30)
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.present(in: view)
            renderer.lastPresentCommandBuffer?.waitUntilCompleted()
        } while (renderer.postProcess.lastHDR == nil || renderer.displayOutput == .standard) && Date() < deadline
        XCTAssertEqual(renderer.displayOutput, .extendedRange(headroom: 4))
        XCTAssertEqual(renderer.sharedFrame?.pixelFormat, .rgba16Float)
        XCTAssertEqual(view.colorPixelFormat, .rgba16Float)
        XCTAssertTrue((view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent ?? false)
    }

    // MARK: - Helpers

    /// `combine_hdr`'s `DISPLAYHDR` branch at frame pixel (x, y): the scene saturated, the bloom's
    /// four taps added, linearised and scaled by RV.x + RV.y · smoothstep(1, 5, luma).
    private static func displayCombined(_ frame: HDRReference.Image, bloom: HDRReference.Image, x: Int, y: Int,
                                        renderVar: SIMD2<Float>) -> SIMD3<Float> {
        let texel = SIMD2(1 / Float(frame.width), 1 / Float(frame.height))
        let uv = SIMD2(Float(x) + 0.5, Float(y) + 0.5) * texel
        let taps: SIMD3<Float> = bloom.sample(uv + texel) + bloom.sample(uv - texel)
            + bloom.sample(uv + SIMD2(texel.x, -texel.y)) + bloom.sample(uv + SIMD2(-texel.x, texel.y))
        let albedo: SIMD3<Float> = simd_clamp(frame[x, y], SIMD3(repeating: 0), SIMD3(repeating: 1)) + taps * 0.25
        let luma = simd_dot(SIMD3<Float>(0.299, 0.587, 0.114), albedo)
        let t = simd_clamp((luma - 1) / 4, 0, 1)
        let factor: Float = renderVar.y * t * t * (3 - 2 * t) + renderVar.x
        return HDRReference.half(HDRReference.linear(simd_max(albedo, SIMD3(repeating: 0))) * factor)
    }

    /// The EDR drawable for review, when `OWE_DISPLAY_HDR_OUT` names a folder: linear values over
    /// the headroom (4), sRGB-encoded, so 1.0 (SDR white) shows as mid-grey and 4 as white.
    private static func write(_ image: HDRReference.Image, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["OWE_DISPLAY_HDR_OUT"], !folder.isEmpty else { return }
        let bytes: [UInt8] = image.pixels.flatMap { pixel -> [UInt8] in
            let value = HDRReference.half(pixel / 4)
            return [HDRReference.srgbByte(value.x), HDRReference.srgbByte(value.y), HDRReference.srgbByte(value.z), 255]
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = URL(fileURLWithPath: folder).appending(path: name + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private static func content(_ postProcessing: GSPostProcessingQuality) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/hdr")
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent())
    }

    private static func view(device: MTLDevice) -> MTKView {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        return view
    }

    /// Draws the fixture with `postProcessing` on a view whose screen has `headroom`, until its
    /// HDR chain has run.
    private func render(_ postProcessing: GSPostProcessingQuality,
                        headroom: SceneDisplayHeadroom) throws -> (MTKView, SceneMetalRenderer) {
        let content = try Self.content(postProcessing)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = Self.view(device: device)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "edr"))
        view.isPaused = true
        renderer.displayHeadroom = { _ in headroom }
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
        } while (drawn < 3 || renderer.postProcess.lastHDR == nil) && Date() < deadline
        // `currentDrawable` hands out the view's drawables in turn: draw until each holds a settled frame.
        for _ in 0..<4 {
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
        }
        return (view, renderer)
    }

    /// The view's drawable bytes (a `bgra8Unorm` one).
    private static func bytes(_ view: MTKView) throws -> [UInt8] {
        let texture = try XCTUnwrap(view.currentDrawable?.texture)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&bytes, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                         mipmapLevel: 0)
        return bytes
    }
}
