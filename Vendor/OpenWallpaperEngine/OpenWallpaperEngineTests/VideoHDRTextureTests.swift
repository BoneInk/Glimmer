import AVFoundation
import Metal
import MetalKit
import XCTest
@testable import OpenWallpaperEngine

/// HDR video on the Metal path (WE 2.8's "Scene DX11 (HDR Support)" framework): the range read
/// from the file, frames decoded as linear BT.709 light, the 8-bit path kept for SDR, and
/// `combine_video_hdr`'s plan. The clips are written here with AVFoundation.
final class VideoHDRTextureTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-hdr-video-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    /// PQ: 100, 203 and 1000 nits of grey, and 100 nits of BT.2020 red.
    private static let pqBands = [100.0, 203, 1000].map { VideoClipFixture.pqSignal(nits: $0) }

    /// The range comes from the file's transfer function, read off the main thread.
    func testTheRangeIsTheFilesTransferFunction() throws {
        let pq = try VideoClipFixture.makeHDR(transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ, bands: Self.pqBands,
                                              in: directory.appending(path: "pq"))
        let hlg = try VideoClipFixture.makeHDR(transfer: AVVideoTransferFunction_ITU_R_2100_HLG, bands: [0.5, 0.75, 1],
                                               in: directory.appending(path: "hlg"))
        let sdr = try VideoClipFixture.make(frames: 4, in: directory.appending(path: "sdr"))
        XCTAssertEqual(try Self.range(of: pq), .pq)
        XCTAssertEqual(try Self.range(of: hlg), .hlg)
        XCTAssertEqual(try Self.range(of: sdr), .sdr)
        XCTAssertEqual(try Self.range(of: directory.appending(path: "missing.mov")), .sdr)
        XCTAssertEqual(VideoDynamicRange(transferFunction: nil), .sdr)
        XCTAssertFalse(VideoDynamicRange.sdr.isHDR)
        XCTAssertTrue(VideoDynamicRange.hlg.isHDR)
    }

    /// A PQ video in HDR mode reaches the scene as linear BT.709 light in half floats, 1.0 = 100
    /// nits: 203 nits is 2.03 and 1000 nits 10, above SDR white, and BT.2020 red is converted to
    /// BT.709 (BT.2087's first column).
    func testAPQVideoDecodesToLinearLight() throws {
        let url = try VideoClipFixture.makeHDR(transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ, bands: Self.pqBands,
                                               in: directory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stream = try XCTUnwrap(VideoTextureStream(url: url, device: device, dynamicRange: .pq))
        defer { stream.stop() }
        XCTAssertEqual(stream.dynamicRange, .pq)
        let texture = try Self.firstFrame(of: stream, device: device)
        XCTAssertEqual(texture.pixelFormat, .rgba16Float)
        let image = try HDRReference.read(texture, device: device)
        let expected: [SIMD3<Float>] = [SIMD3(repeating: 1), SIMD3(repeating: 2.03), SIMD3(repeating: 10),
                                        SIMD3(1.6605, -0.1246, -0.0182)]
        for (band, value) in expected.enumerated() {
            let pixel = image[band * 16 + 8, 32]
            for channel in 0..<3 {
                XCTAssertEqual(pixel[channel], value[channel], accuracy: max(0.03 * abs(value[channel]), 0.02),
                               "band \(band) channel \(channel): \(pixel)")
            }
        }
    }

    /// An SDR video keeps the 8-bit BGRA frames sampled as they are, with no conversion pass.
    func testAnSDRVideoKeepsTheEightBitPath() throws {
        let url = try VideoClipFixture.make(frames: 30, in: directory)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stream = try XCTUnwrap(VideoTextureStream(url: url, device: device))
        defer { stream.stop() }
        XCTAssertEqual(stream.dynamicRange, .sdr)
        let texture = try Self.firstFrame(of: stream, device: device)
        XCTAssertEqual(texture.pixelFormat, .bgra8Unorm)
    }

    /// `g_HDRParams` is a built-in: display HDR's RV, or SDR white on a display without headroom.
    func testHDRParamsAreTheDevicePair() {
        var frame = BuiltinFrameContext()
        XCTAssertTrue(BuiltinUniforms.isBuiltin("g_HDRParams"))
        XCTAssertEqual(BuiltinUniforms.value(named: "g_HDRParams", frame: frame, pass: BuiltinPassContext(targetSize: SIMD2(1, 1))),
                       [1, 0])
        frame.hdrParams = SceneHDRChain.videoHDRParams(displayHDR: SIMD2(1, 3))
        XCTAssertEqual(BuiltinUniforms.value(named: "g_HDRParams", frame: frame, pass: BuiltinPassContext(targetSize: SIMD2(1, 1))),
                       [1, 3])
        XCTAssertEqual(SceneHDRChain.videoHDRParams(displayHDR: nil), SIMD2<Float>(1, 0.5))
        XCTAssertTrue(UniformProgram.timeVarying.contains("g_HDRParams"))
    }

    /// End to end: a PQ video wallpaper on the Metal path under "Ultra (Display HDR)" on a screen
    /// with headroom 4 draws a float frame of linear light, finished by `combine_video_hdr` onto
    /// the EDR drawable: 203 nits shows at 2.03 × SDR white, 1000 nits clamps at 2 · (4 − 1) = 6.
    /// Under "Ultra" the same video plays on the 8-bit path.
    func testAPQVideoWallpaperReachesTheEDRDrawable() throws {
        _ = try Fixtures.assets()
        let clip = try VideoClipFixture.makeHDR(transfer: AVVideoTransferFunction_SMPTE_ST_2084_PQ, bands: Self.pqBands,
                                                in: directory)
        let wallpaper = WEWallpaper(using: WEProject(file: clip.lastPathComponent, preview: "p.jpg", title: "hdr", type: "video"),
                                    where: directory)
        let model = SceneContentLoader(wallpaper: wallpaper)
        XCTAssertFalse(try Self.content(model, .ultra).videoHDR, "SDR output keeps the 8-bit path")
        let content = try Self.content(model, .displayhdr)
        XCTAssertTrue(content.videoHDR)
        XCTAssertTrue(content.engineCombos.hdr)
        XCTAssertNotNil(content.hdrChain)
        model.updateVideoPlayback(playRate: 1, audioRate: 0, audioLevel: 0, audioEnabled: false, volume: 0)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 64, height: 64)
        view.isPaused = true
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "hdr-video"))
        defer { renderer.releaseContent() }
        renderer.displayHeadroom = { _ in SceneDisplayHeadroom(potential: 4, current: 4) }
        renderer.renderSettings.postProcessing = .displayhdr
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var combined: HDRReference.Image?
        var seen = "no HDR combine ran"
        let deadline = Date().addingTimeInterval(30)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if let record = renderer.postProcess.lastHDR {
                let image = try HDRReference.read(record.combined, device: device)
                let frame = try HDRReference.read(record.frame, device: device)
                seen = "combined \(image.width)×\(image.height) \(image[image.width * 5 / 8, image.height / 2]), "
                    + "frame \(frame.width)×\(frame.height) \(frame[frame.width * 5 / 8, frame.height / 2]), "
                    + "output \(renderer.displayOutput), content \(renderer.hasContent)"
                if image[image.width * 5 / 8, image.height / 2].x > 1 { combined = image }
            }
        } while combined == nil && Date() < deadline
        let shown = try XCTUnwrap(combined, "the HDR video never reached the combine: \(seen)")
        XCTAssertEqual(renderer.displayOutput, .extendedRange(headroom: 4))
        XCTAssertEqual(view.colorPixelFormat, .rgba16Float)
        func band(_ index: Int) -> Float { shown[shown.width * (2 * index + 1) / 8, shown.height / 2].x }
        XCTAssertEqual(band(0), 1, accuracy: 0.05, "100 nits is SDR white")
        XCTAssertEqual(band(1), 2.03, accuracy: 0.08, "203 nits")
        XCTAssertEqual(band(2), 6, accuracy: 0.05, "1000 nits, clamped at 2 · (headroom − 1)")
    }

    // MARK: - Helpers

    /// `model`'s content under `postProcessing`, built off the main thread as the app builds it.
    private static func content(_ model: SceneContentLoader, _ postProcessing: GSPostProcessingQuality) throws -> SceneMetalContent {
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        var content: SceneMetalContent?
        let done = XCTestExpectation(description: "content built")
        DispatchQueue.global().async {
            content = model.metalContent()
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 30), .completed)
        return try XCTUnwrap(content)
    }

    private static func range(of url: URL) throws -> VideoDynamicRange {
        var range: VideoDynamicRange?
        let done = XCTestExpectation(description: "range read")
        DispatchQueue.global().async {
            range = VideoDynamicRange.of(url)
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 10), .completed)
        return try XCTUnwrap(range)
    }

    /// Plays `stream` and returns its first frame, prepared on a command buffer as a scene frame is.
    private static func firstFrame(of stream: VideoTextureStream, device: MTLDevice) throws -> MTLTexture {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        stream.update(playRate: 1, audioRate: 0, audioLevel: 0, paceAmount: 0)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            stream.prepareFrame(on: commands)
            let texture = stream.currentTexture()
            stream.holdCurrentFrame(until: commands)
            commands.commit()
            commands.waitUntilCompleted()
            if let texture { return texture }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("no video frame decoded within 10 s")
        throw CocoaError(.featureUnsupported)
    }
}
