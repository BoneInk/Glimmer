import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// WE's MSAA setting (`msaa`: none, x2, x4, x8; none is WE's default): the scene pass draws into a
/// multisampled target and resolves into `_rt_FullFrameBuffer` (`wallpaper64.exe` 0x140181dcc,
/// 0x140183550, 0x1400d3310). The fixture is a white square turned 0.3 rad on black.
final class SceneMSAATests: XCTestCase {
    private static let size = SIMD2(480, 272)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = Fixtures.url("Scenes/msaa")
    }

    override func tearDownWithError() throws {
        if let directory { Fixtures.removeStoredSettings(for: directory) }
    }

    /// WE's default is none, stored under WE's own key; a value saved under the old key (while the
    /// setting did nothing, defaulting to x2) is left behind.
    func testTheSettingIsWEsWithWEsDefault() throws {
        XCTAssertEqual(GlobalSettings().antiAliasing, .none)
        XCTAssertEqual(GSAntiAliasingQuality.allCases.map(\.sampleCount), [1, 2, 4, 8])
        let old = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"antiAliasing": "msaa_x2"}"#.utf8))
        XCTAssertEqual(old.antiAliasing, .none)
        let saved = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"msaa": "msaa_x4"}"#.utf8))
        XCTAssertEqual(saved.antiAliasing, .msaa_x4)
        XCTAssertEqual(SceneRenderSettings(saved).antiAliasing, .msaa_x4)
    }

    /// A count the GPU lacks falls to the most below it that it has.
    func testTheSampleCountIsOneTheGPUSupports() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var settings = SceneRenderSettings()
        XCTAssertEqual(settings.sceneSampleCount(on: device), 1)
        for quality in GSAntiAliasingQuality.allCases {
            settings.antiAliasing = quality
            let count = settings.sceneSampleCount(on: device)
            XCTAssertTrue(device.supportsTextureSampleCount(count), "\(quality)")
            XCTAssertLessThanOrEqual(count, quality.sampleCount)
        }
        settings.antiAliasing = .msaa_x4
        XCTAssertEqual(settings.sceneSampleCount(on: device), device.supportsTextureSampleCount(4) ? 4 : 2)
    }

    /// Without MSAA the square's edges are hard (every pixel black or white); with it they are
    /// smoothed by coverage and the rest of the frame is unchanged.
    func testMSAASmoothsTheEdges() throws {
        _ = try Fixtures.assets()
        let hard = try render(.none)
        let greys = hard.filter { $0 != 0 && $0 != 255 }.count
        XCTAssertEqual(greys, 0, "no MSAA: hard edges")
        let whites = hard.filter { $0 == 255 }.count
        XCTAssertGreaterThan(whites, 160 * 96 * 9 / 10, "the square is drawn")

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        for quality in [GSAntiAliasingQuality.msaa_x2, .msaa_x4] where device.supportsTextureSampleCount(quality.sampleCount) {
            let smooth = try render(quality)
            let edges = zip(hard, smooth).filter { $0 != $1 }
            XCTAssertGreaterThan(edges.count, 200, "\(quality): the edges are antialiased")
            XCTAssertTrue(edges.allSatisfy { abs(Int($0) - Int($1)) < 255 }, "\(quality): only edge pixels change")
            XCTAssertGreaterThan(smooth.filter { $0 != 0 && $0 != 255 }.count, 200, "\(quality): coverage greys")
            // Away from the edges, the same frame.
            XCTAssertEqual(smooth.filter { $0 == 255 }.count, whites, accuracy: whites / 20)
        }
    }

    /// The red channel of every drawable pixel (the square is white on black).
    private func render(_ quality: GSAntiAliasingQuality) throws -> [UInt8] {
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/msaa/project.json"))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "msaa-\(quality)"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings.antiAliasing = quality
        renderer.setPlacement(.stretch)
        renderer.setContent(content)
        var drawn = 0
        let deadline = Date().addingTimeInterval(30)
        // Enough frames for the layer's material pipeline to compile, then a few more.
        while drawn < 30, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            renderer.draw(in: view)
            renderer.lastCommandBuffer?.waitUntilCompleted()
            if renderer.hasContent { drawn += 1 }
        }
        var bytes = [UInt8](repeating: 0, count: Self.size.x * Self.size.y * 4)
        view.currentDrawable?.texture.getBytes(&bytes, bytesPerRow: Self.size.x * 4,
                                               from: MTLRegionMake2D(0, 0, Self.size.x, Self.size.y), mipmapLevel: 0)
        return stride(from: 2, to: bytes.count, by: 4).map { bytes[$0] }
    }
}
