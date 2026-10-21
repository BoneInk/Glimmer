import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// A scene's first frames, which its loading picture covers until the renderer has drawn one with
/// every pass in it (`SceneMetalRenderer.hasCompleteFrame`). The fixture's solid layer blends an
/// effect at half alpha into a target nothing drew into yet, then runs it again as its last pass,
/// which draws the layer into the scene with the layer's `translucent` blending (WE's last pass,
/// `SceneMetalRenderer.lastPassDrawsIntoScene`). The fullscreen layer's motion blur, a built-in
/// effect the fixture has no copy of the materials of, is dropped as WE drops it.
@MainActor
final class SceneStartFrameTests: XCTestCase {
    private struct Drawn {
        let complete: Bool
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// The first complete frame is the scene as it then stays: the half-covered layer over
    /// transparent black, a flat colour inside it with nothing left from whatever the targets'
    /// memory held, as bright as the frames after it.
    func testFirstCompleteFrameIsTheSettledScene() throws {
        _ = try Fixtures.assets()
        let frames = try draw(Fixtures.url("Scenes/start-frame"), count: 20)
        let first = try XCTUnwrap(frames.firstIndex(where: \.complete), "no complete frame")
        XCTAssertTrue(frames[first...].allSatisfy(\.complete), "a complete frame stays complete")
        let shown = frames[first]
        let later = frames[min(first + 2, frames.count - 1)]
        XCTAssertEqual(Self.mean(shown), Self.mean(later), accuracy: 0.5, "as bright as the frames after it")
        // Inside the layer: one colour. Over transparent black the first half cover leaves half the
        // colour at a quarter alpha; the second, the last pass, draws that half colour at half alpha
        // into the scene.
        let inside = Self.channels(shown, x: shown.width / 4..<shown.width * 3 / 4, y: shown.height / 4..<shown.height * 3 / 4)
        for (channel, layer) in zip(inside, [0.8, 0.6, 0.2]) {
            XCTAssertLessThan(channel.deviation, 2, "no pattern inside the layer")
            XCTAssertEqual(channel.mean / 255, layer / 4, accuracy: 0.01, "the half cover over transparent black")
        }
    }

    /// Draws `count` frames 1/30 s apart, each read back with whether the renderer had drawn a
    /// complete frame by then.
    private func draw(_ directory: URL, count: Int) throws -> [Drawn] {
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = SIMD2<Float>(256, 128)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 256, height: 128), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 256, height: 128)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "start-frame"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(renderer.hasCompleteFrame, "nothing is drawn yet")
        var frames: [Drawn] = []
        for _ in 0..<count {
            now += 1.0 / 30
            renderer.renderShared([SceneViewport(drawableSize: size, pointSize: size, cursor: nil, frameRateLimit: 30)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            let texture = try XCTUnwrap(renderer.sharedFrame)
            frames.append(Drawn(complete: renderer.hasCompleteFrame, pixels: try TextureUploadTests.read(texture, device: device),
                                width: texture.width, height: texture.height))
            // Compiles land off the render thread.
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return frames
    }

    private static func mean(_ frame: Drawn) -> Double {
        var sum = 0.0
        for index in stride(from: 0, to: frame.pixels.count, by: 4) {
            sum += Double(frame.pixels[index]) + Double(frame.pixels[index + 1]) + Double(frame.pixels[index + 2])
        }
        return sum / Double(frame.pixels.count / 4 * 3)
    }

    /// The red, green and blue channels' mean and standard deviation over a region.
    private static func channels(_ frame: Drawn, x: Range<Int>, y: Range<Int>) -> [(mean: Double, deviation: Double)] {
        [0, 1, 2].map { channel in
            var values: [Double] = []
            for row in y { for column in x { values.append(Double(frame.pixels[(row * frame.width + column) * 4 + channel])) } }
            let mean = values.reduce(0, +) / Double(values.count)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
            return (mean, variance.squareRoot())
        }
    }
}
