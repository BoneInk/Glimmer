import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// Memory across content swaps (test-risks LR10): one renderer switched between the HDR fixture
/// (float targets, WE's HDR chain) and an LDR one ten times holds, after the last HDR visit, no more
/// than it held once its caches settled (after the third round trip), give or take 5% or 8 MB, and a
/// content without HDR holds no float target. The allocator moves by a few MB between runs (more on
/// CI's virtual GPU); a leaked set of HDR targets is ~4 MB a round trip, 28 MB over the seven.
final class LightingMemoryTests: XCTestCase {
    private static let size = SIMD2(960, 544)

    private func content(_ fixture: String, _ postProcessing: GSPostProcessingQuality) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/\(fixture)")
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.postProcessing = postProcessing
        model.setRenderSettings(settings)
        return try XCTUnwrap(model.metalContent())
    }

    func testSwitchingInAndOutOfHDRReturnsItsMemory() throws {
        _ = try Fixtures.assets()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: Self.size.x, height: Self.size.y), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: Self.size.x, height: Self.size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "memory"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings.postProcessing = .ultra
        renderer.setPlacement(.stretch)
        let hdr = try content("hdr", .ultra)
        let ldr = try content("timeline", .ultra)
        XCTAssertTrue(hdr.engineCombos.hdr)
        XCTAssertFalse(ldr.engineCombos.hdr)

        func show(_ content: SceneMetalContent) -> Int {
            renderer.setContent(content)
            let deadline = Date().addingTimeInterval(30)
            while renderer.postProcess.drawsHDR != content.engineCombos.hdr || !renderer.hasContent, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            for _ in 0..<5 {
                renderer.draw(in: view)
                renderer.lastCommandBuffer?.waitUntilCompleted()
            }
            return device.currentAllocatedSize
        }
        var first = show(hdr)
        var last = first
        for round in 0..<10 {
            _ = show(ldr)
            XCTAssertNotEqual(renderer.lastSceneTarget?.pixelFormat, .rgba16Float, "an LDR content draws into 8 bits")
            XCTAssertFalse(renderer.postProcess.holdsHDROutput)
            last = show(hdr)
            if round == 2 { first = last }
        }
        let allowance = max(first / 20, 8 << 20)
        XCTAssertLessThanOrEqual(last - first, allowance, "\(first) → \(last) bytes from the third round trip to the tenth")
    }
}
