import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The cost of lighting, bloom, HDR, reflection and volumetrics on the library's scenes that use
/// them (docs/lighting-plan.md §1.5; test-risks LR9, LR10), at 1920×1080 and 5120×2880: whole
/// frames drawn by the renderer at full scene detail under each setting that turns a stage on or
/// off, with the GPU time (median of the measured frames) and the Metal memory the device holds
/// once the frames are drawn. A stage's cost is the difference between two rows. Only runs when
/// `OWE_LIGHTING_BENCH` is set (`TEST_RUNNER_OWE_LIGHTING_BENCH` through xcodebuild): `1` for the
/// default scenes, or a comma-separated list of workshop ids. Written to `OWE_BENCH_OUT` when set.
final class LightingFrameBenchmarkTests: XCTestCase {
    private static let scenes = ["3352730400", "3606529469", "3803167460", "2515150033", "3270035750", "3639372043"]
    private static let frames = 60

    private struct Mode {
        var name: String
        var settings: SceneRenderSettings
    }

    private static var modes: [Mode] {
        func mode(_ name: String, _ change: (inout SceneRenderSettings) -> Void) -> Mode {
            var settings = SceneRenderSettings()
            settings.sceneDetail = .full
            settings.renderResolution = .yourDisplay
            settings.postProcessing = .ultra
            change(&settings)
            return Mode(name: name, settings: settings)
        }
        return [
            mode("ultra", { _ in }),
            mode("enabled", { $0.postProcessing = .enabled }),
            mode("no post", { $0.postProcessing = .disabled }),
            mode("ultra, no reflection", { $0.reflection = false }),
            mode("ultra, no volumetrics", { $0.volumetrics = .disabled }),
        ]
    }

    func testLightingStageCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_LIGHTING_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_LIGHTING_BENCH to run the lighting benchmark")
        }
        let ids = request == "1" ? Self.scenes : request.split(separator: ",").map(String.init)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-lighting-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) } // scratch cleanup
        let sizes = [SIMD2(1920, 1080), SIMD2(5120, 2880)]
        var lines = ["scene\tsize\tmode\ttarget\tGPU median ms\tGPU min ms\tMetal MB held\ttargets MB"]
        for id in ids {
            guard let directory = LightingLibraryDecodeTests.roots.lazy
                .map({ $0.appending(path: id, directoryHint: .isDirectory) })
                .first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "project.json").path) }) else {
                lines.append("\(id)\tnot in the library")
                continue
            }
            let data = try Data(contentsOf: directory.appending(path: "project.json"))
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
            let project = try decodeTolerant(WEProject.self, from: Data(text.utf8))
            defer { Fixtures.removeStoredSettings(for: directory) }
            for size in sizes {
                for mode in Self.modes {
                    let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
                    model.setRenderSettings(mode.settings)
                    guard let content = model.metalContent() else { continue }
                    let services = SceneScriptServices(prelude: SceneScriptPrelude.load(),
                                                       storage: SceneScriptStorage(directory: storage),
                                                       media: SceneScriptReplayMediaSource(), spectrum: { .silent })
                    let result = try autoreleasepool { () -> (Double, Double, Double, String, String) in
                        let before = device.currentAllocatedSize
                        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x, height: size.y), device: device)
                        view.colorPixelFormat = .bgra8Unorm
                        view.framebufferOnly = false
                        view.autoResizeDrawable = false
                        view.drawableSize = CGSize(width: size.x, height: size.y)
                        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "bench"))
                        view.isPaused = true
                        renderer.renderSettings = mode.settings
                        renderer.setPlacement(.stretch)
                        renderer.scripts.frameWait = 5
                        var now: CFTimeInterval = 1000
                        renderer.wallTime = { now }
                        renderer.setContent(content)
                        let deadline = Date().addingTimeInterval(60)
                        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
                        func draw() -> Double? {
                            now += 1.0 / 30
                            renderer.draw(in: view)
                            renderer.lastCommandBuffer?.waitUntilCompleted()
                            renderer.scripts.wallpaper?.waitUntilIdle()
                            RunLoop.main.run(until: Date())
                            return renderer.lastCommandBuffer.map { ($0.gpuEndTime - $0.gpuStartTime) * 1000 }
                        }
                        // Pipelines compile in the background: warm up until the frame time settles.
                        for _ in 0..<40 { _ = draw() }
                        let times = (0..<Self.frames).compactMap { _ in draw() }.sorted()
                        let held = Double(device.currentAllocatedSize) - Double(before)
                        let target = renderer.lastSceneTarget.map { "\($0.width)x\($0.height) \($0.pixelFormat == .rgba16Float ? "F16" : "8")" } ?? "-"
                        let targets = renderer.frameTargetBytes.filter { $0.value > 0 }.sorted { $0.key < $1.key }
                            .map { String(format: "%@ %.0f", $0.key, Double($0.value) / 1_048_576) }.joined(separator: ", ")
                        renderer.releaseContent()
                        return (times.isEmpty ? 0 : times[times.count / 2], times.first ?? 0, held / 1_048_576, target, targets)
                    }
                    lines.append(String(format: "%@\t%dx%d\t%@\t%@\t%.2f\t%.2f\t%.0f\t%@", id, size.x, size.y, mode.name,
                                        result.3, result.0, result.1, result.2, result.4))
                }
            }
        }
        let report = lines.joined(separator: "\n")
        print("Lighting stage cost:\n\(report)")
        if let out = environment["OWE_BENCH_OUT"] { try report.write(toFile: out, atomically: true, encoding: .utf8) }
    }
}
