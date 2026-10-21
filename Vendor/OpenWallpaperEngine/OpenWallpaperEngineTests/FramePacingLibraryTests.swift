import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// What adaptive rate and idle skipping save on real wallpapers (efficiency-plan-2d notes WP2-C
/// metrics): each scene in `OWE_LIBRARY` runs in real time with a still cursor and no audio, once
/// at a fixed rate drawing every frame and once paced, and the drawn rate and GPU time per second
/// are compared. Runs with `OWE_PACING_METRICS=1`; `OWE_PACING_FPS` (default 30) and
/// `OWE_PACING_STOP` (default 4) set the limits.
@MainActor
final class FramePacingLibraryTests: XCTestCase {
    private struct Result {
        var ticks = 0
        var drawn = 0
        var gpuMilliseconds = 0.0
        var seconds = 0.0
        var drawnRate: Double { seconds > 0 ? Double(drawn) / seconds : 0 }
        var gpuPerSecond: Double { seconds > 0 ? gpuMilliseconds / seconds : 0 }
    }

    func testPacingOnTheLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OWE_PACING_METRICS"] == "1", "set OWE_PACING_METRICS=1 to measure pacing")
        _ = try Fixtures.assets()
        let library = LibrarySweepTests.libraryRoot
        let names = try FileManager.default.contentsOfDirectory(atPath: library.path).sorted()
        let fps = Int(environment["OWE_PACING_FPS"] ?? "") ?? 30
        let stop = Int(environment["OWE_PACING_STOP"] ?? "") ?? QualityEfficiency.defaultStop
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-pacing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // optional: scratch may not exist
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        var lines = [String(format: "Pacing at %d fps, stop %d: drawn fps and GPU ms per second, fixed → paced", fps, stop)]
        var fixedRates: [Double] = [], pacedRates: [Double] = [], fixedGPU: [Double] = [], pacedGPU: [Double] = []
        for name in names {
            let directory = library.appending(path: name, directoryHint: .isDirectory)
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a wallpaper
                  project.type.lowercased() == "scene" else { continue }
            defer { Fixtures.removeStoredSettings(for: directory) }
            let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
            guard let content = model.metalContent() else { lines.append("\(name): no content"); continue }
            let fixed = try run(content, device: device, services: services, fps: fps, stop: stop, paced: false)
            let paced = try run(content, device: device, services: services, fps: fps, stop: stop, paced: true)
            fixedRates.append(fixed.drawnRate); pacedRates.append(paced.drawnRate)
            fixedGPU.append(fixed.gpuPerSecond); pacedGPU.append(paced.gpuPerSecond)
            lines.append(String(format: "%@ “%@”: %.1f → %.1f fps (ticks %.1f/s), GPU %.1f → %.1f ms/s", name, project.title,
                                fixed.drawnRate, paced.drawnRate, Double(paced.ticks) / max(paced.seconds, 0.001),
                                fixed.gpuPerSecond, paced.gpuPerSecond))
        }
        func mean(_ values: [Double]) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        lines.append(String(format: "Average over %d scenes: %.1f → %.1f fps, GPU %.1f → %.1f ms/s", pacedRates.count,
                            mean(fixedRates), mean(pacedRates), mean(fixedGPU), mean(pacedGPU)))
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = environment["OWE_PACING_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// A still scene (one full-scene image, no clock, scripts, audio or particles): its GPU time per
    /// second drawing every frame, and idle once paced.
    func testIdleGPUOnAStillScene() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["OWE_PACING_METRICS"] == "1", "set OWE_PACING_METRICS=1 to measure pacing")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let size = NSSize(width: 1920, height: 1080)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(origin: .zero, size: size), angle: 30)
        image.unlockFocus()
        var layer = SceneMetalLayer(
            id: "1", name: "still", source: .image(image), position: SIMD2(960, 540), size: SIMD2(1920, 1080),
            scale: SIMD2(1, 1), opacity: 1, brightness: 1, color: SIMD4(repeating: 1), text: nil, parallaxDepth: .zero,
            perspective: false, rotation: 0)
        layer.order = 0
        let content = SceneMetalContent(
            size: SIMD2(1920, 1080), layers: [layer], particleSystems: [],
            bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1)))
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(),
                                           storage: SceneScriptStorage(directory: FileManager.default.temporaryDirectory),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let fixed = try run(content, device: device, services: services, fps: 60, stop: 4, paced: false)
        let paced = try run(content, device: device, services: services, fps: 60, stop: 4, paced: true)
        let report = String(format: "Still scene at 60 fps: %.1f → %.1f frames drawn/s (ticks %.1f/s), GPU %.2f → %.2f ms/s",
                            fixed.drawnRate, paced.drawnRate, Double(paced.ticks) / max(paced.seconds, 0.001),
                            fixed.gpuPerSecond, paced.gpuPerSecond)
        print(report)
        if let path = environment["OWE_PACING_OUT"] {
            try report.write(toFile: path + ".still", atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(paced.drawn, 0, "a still scene draws nothing once settled")
    }

    /// 1.5 s to load and settle, then 3 s measured, ticking like a 120 Hz display at the pacing's
    /// cadence (or at `fps` drawing every frame when not `paced`).
    private func run(_ content: SceneMetalContent, device: MTLDevice, services: SceneScriptServices,
                     fps: Int, stop: Int, paced: Bool) throws -> Result {
        let size = SIMD2<Int>(1920, 1080)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x / 2, height: size.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "pacing"))
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.skipsIdleFrames = paced
        renderer.framePacing.limits = .init(userLimit: fps, policy: QualityEfficiency(stop: stop))
        renderer.setContent(content)
        defer { renderer.releaseContent() }
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        let viewport = SceneViewport(drawableSize: SIMD2(Float(size.x), Float(size.y)),
                                     pointSize: SIMD2(Float(size.x / 2), Float(size.y / 2)), cursor: SIMD2(300, 200),
                                     frameRateLimit: fps)
        var result = Result()
        let start = CACurrentMediaTime()
        let measureFrom = start + 1.5, end = start + 4.5
        var next = start
        while true {
            let now = CACurrentMediaTime()
            guard now < end else { break }
            if next > now { RunLoop.main.run(until: Date().addingTimeInterval(next - now)) }
            let before = renderer.encodedFrames
            let previous = renderer.lastCommandBuffer
            renderer.renderShared([viewport])
            let rate = paced ? FramePacing.cadence(renderer.framePacing.targetRate, refreshRate: 120) : fps
            next += 1.0 / Double(max(rate, 1))
            guard CACurrentMediaTime() >= measureFrom else { continue }
            result.ticks += 1
            guard renderer.encodedFrames != before, let buffer = renderer.lastCommandBuffer, buffer !== previous else { continue }
            buffer.waitUntilCompleted()
            result.drawn += 1
            result.gpuMilliseconds += (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
        }
        result.seconds = end - measureFrom
        return result
    }
}
