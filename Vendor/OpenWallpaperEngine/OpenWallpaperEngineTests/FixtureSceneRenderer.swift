import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Draws a fixture scene headlessly through the real loader and renderer, as one display of
/// `points` at `pixelsPerPoint` (2 is a Retina backing scale), and returns the finished frame. The
/// scene clock runs 1/30 s a frame; the frame is taken once it has stopped changing (pipelines
/// compile off the render thread, and timelines in the fixtures hold their last frame).
struct FixtureSceneRenderer {
    struct Frame {
        let width: Int
        let height: Int
        /// RGBA, row 0 at the top.
        let pixels: [UInt8]
        /// Layers the frame drew at the output's backing pixels (`SceneNativeDetailLayers`).
        var promoted = 0

        func pixel(_ x: Int, _ y: Int) -> SIMD4<Int> {
            let index = (y * width + x) * 4
            return SIMD4(Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]), Int(pixels[index + 3]))
        }
    }

    let directory: URL
    /// The scene file inside `directory` (the project's `file`).
    var sceneFile = "scene.json"
    var points = SIMD2<Float>(480, 272)
    var pixelsPerPoint: Float = 1
    var settings = SceneRenderSettings()
    /// Runs on the renderer before its content is set.
    var configure: (SceneMetalRenderer) -> Void = { _ in }

    func render() throws -> Frame {
        defer { Fixtures.removeStoredSettings(for: directory) }
        var projectJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appending(path: "project.json"))) as? [String: Any])
        projectJSON["file"] = sceneFile
        let project = try JSONDecoder().decode(WEProject.self, from: JSONSerialization.data(withJSONObject: projectJSON))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        model.setRenderSettings(settings)
        let content = try XCTUnwrap(model.metalContent(), "\(sceneFile): no content")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let drawable = points * pixelsPerPoint
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: CGFloat(points.x), height: CGFloat(points.y)), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: CGFloat(drawable.x), height: CGFloat(drawable.y))
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil,
                                                        screenID: "fixture-\(sceneFile)-\(pixelsPerPoint)"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.renderSettings = settings
        configure(renderer)
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent, "\(sceneFile) never got its content")
        var previous: [UInt8]?
        var frame = 0
        while Date() < deadline {
            now += 1.0 / 30
            OWEPhaseTiming.measure(.render, frames: 1) {
                renderer.renderShared([SceneViewport(drawableSize: drawable, pointSize: points, cursor: nil, frameRateLimit: 30)])
            }
            OWEPhaseTiming.measure(.gpuWait) { renderer.lastCommandBuffer?.waitUntilCompleted() }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            frame += 1
            guard frame % 10 == 0, let texture = renderer.sharedFrame else { continue }
            let bytes = try TextureUploadTests.read(texture, device: device)
            if frame >= 60, bytes == previous {
                return Frame(width: texture.width, height: texture.height, pixels: bytes,
                             promoted: renderer.promotedDetailLayers)
            }
            previous = bytes
        }
        XCTFail("\(sceneFile) never settled")
        let texture = try XCTUnwrap(renderer.sharedFrame)
        return Frame(width: texture.width, height: texture.height, pixels: try TextureUploadTests.read(texture, device: device))
    }
}
