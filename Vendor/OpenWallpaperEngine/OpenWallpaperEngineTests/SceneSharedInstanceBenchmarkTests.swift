import XCTest
import MetalKit
@testable import OpenWallpaperEngine

/// The same scene on two displays, before and after the shared instance: two renderers each
/// drawing their own frame (as every display did), against one renderer rendering once for both
/// and each display presenting it. Only runs when asked: `OWE_SHARED_BENCH`
/// (`TEST_RUNNER_OWE_SHARED_BENCH` through xcodebuild) lists workshop ids; skipped otherwise and
/// without the library. The displays are `OWE_SHARED_BENCH_SIZES` (default 2560x1440,1920x1080).
/// A row gives the main thread's CPU time for a frame's draws and the GPU time of its command
/// buffers (medians of 60 frames). Written to `OWE_BENCH_OUT` when set.
@MainActor
final class SceneSharedInstanceBenchmarkTests: XCTestCase {
    private struct Measure {
        var cpu = 0.0
        var gpu = 0.0
    }

    func testSharedInstanceFrameCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_SHARED_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_SHARED_BENCH to run the shared-instance benchmark")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-shared-bench-\(UUID().uuidString)")
        defer {
            do {
                if FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
            } catch {
                XCTFail("Removing \(storage.path) failed: \(error)")
            }
        }
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let sizes = (environment["OWE_SHARED_BENCH_SIZES"] ?? "2560x1440,1920x1080").split(separator: ",").compactMap { entry -> SIMD2<Int>? in
            let parts = entry.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? SIMD2(parts[0], parts[1]) : nil
        }
        var lines = ["Same scene on \(sizes.map { "\($0.x)x\($0.y)" }.joined(separator: " + ")) (ms per frame, medians): CPU, GPU"]
        for id in request.split(separator: ",") {
            let directory = library.appending(path: String(id), directoryHint: .isDirectory)
            let data = try Data(contentsOf: directory.appending(path: "project.json"))
            let project = try JSONDecoder().decode(WEProject.self, from: data)
            guard project.type.lowercased() == "scene" else {
                lines.append("\(id): not a scene; skipped")
                continue
            }
            let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
            defer { Fixtures.removeStoredSettings(for: directory) }
            let content = try XCTUnwrap(model.metalContent(), "\(id): no content")
            let before = try perDisplay(content, sizes: sizes, device: device, services: services)
            let after = try shared(content, sizes: sizes, device: device, services: services)
            lines.append(String(format: "%@ “%@”: before cpu %.3f gpu %.3f | after cpu %.3f gpu %.3f | ratio cpu %.2f gpu %.2f",
                                String(id), project.title, before.cpu, before.gpu, after.cpu, after.gpu,
                                after.cpu / max(before.cpu, 1e-6), after.gpu / max(before.gpu, 1e-6)))
            print(lines.last!)
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = environment["OWE_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func view(_ size: SIMD2<Int>, device: MTLDevice) -> MTKView {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x / 2, height: size.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        return view
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    private func settle(_ renderers: [SceneMetalRenderer]) {
        spin(until: { renderers.allSatisfy(\.hasContent) }, timeout: 60)
    }

    /// Before: a renderer per display, each drawing the whole scene.
    private func perDisplay(_ content: SceneMetalContent, sizes: [SIMD2<Int>], device: MTLDevice,
                            services: SceneScriptServices) throws -> Measure {
        let views = sizes.map { view($0, device: device) }
        let renderers = try views.enumerated().map { index, view in
            try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "bench\(index)"))
        }
        for (renderer, view) in zip(renderers, views) {
            view.isPaused = true
            renderer.setPlacement(.fill)
            renderer.setContent(content)
        }
        defer { renderers.forEach { $0.releaseContent() } }
        settle(renderers)
        return frames(zip(renderers, views).map { renderer, view in
            { () -> MTLCommandBuffer? in
                renderer.draw(in: view)
                return renderer.lastCommandBuffer
            }
        }) {
            renderers.forEach { $0.scripts.wallpaper?.waitUntilIdle() }
        }
    }

    /// After: one renderer rendering for both displays, each presenting the frame.
    private func shared(_ content: SceneMetalContent, sizes: [SIMD2<Int>], device: MTLDevice,
                        services: SceneScriptServices) throws -> Measure {
        let views = sizes.map { view($0, device: device) }
        let renderer = try XCTUnwrap(SceneMetalRenderer(pixelFormat: .bgra8Unorm, scriptServices: services, screenID: "bench"))
        for view in views {
            renderer.configure(view)
            view.isPaused = true
        }
        renderer.setPlacement(.fill)
        renderer.setContent(content)
        defer { renderer.releaseContent() }
        settle([renderer])
        let render = { () -> MTLCommandBuffer? in
            renderer.renderShared(views.map { SceneViewport($0) })
            return renderer.lastCommandBuffer
        }
        return frames([render] + views.map { view in
            { () -> MTLCommandBuffer? in
                renderer.present(in: view)
                return renderer.lastPresentCommandBuffer
            }
        }) {
            renderer.scripts.wallpaper?.waitUntilIdle()
        }
    }

    /// 150 frames at 60 fps to compile and fill, then 60 measured back to back. A frame is its
    /// `steps` (each display's draw, or the shared render and each display's present), each run
    /// and finished on the GPU before the next, so their GPU times don't overlap.
    private func frames(_ steps: [() -> MTLCommandBuffer?], idle: () -> Void) -> Measure {
        var cpu: [Double] = [], gpu: [Double] = []
        for frame in 0..<210 {
            if frame < 150 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) } else { RunLoop.main.run(until: Date()) }
            var cpuTime = 0.0, gpuTime = 0.0
            for step in steps {
                let start = CACurrentMediaTime()
                let buffer = step()
                cpuTime += CACurrentMediaTime() - start
                buffer?.waitUntilCompleted()
                gpuTime += buffer.map { $0.gpuEndTime - $0.gpuStartTime } ?? 0
            }
            idle()
            guard frame >= 150 else { continue }
            cpu.append(cpuTime * 1000)
            gpu.append(gpuTime * 1000)
        }
        return Measure(cpu: Self.median(cpu), gpu: Self.median(gpu))
    }
}
