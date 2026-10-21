import XCTest
import MetalKit
import Darwin
@testable import OpenWallpaperEngine

/// What loading a wallpaper's textures costs, and the frames they draw, on chosen library
/// wallpapers: the time to build the content (decoding every texture), the time for the renderer
/// to take it (uploading them), the GPU memory it holds and the process footprint after both, and
/// the GPU time of a frame. The frames, drawn on a fixed clock, are written under
/// `OWE_TEXTURE_BENCH_OUT`; with `OWE_TEXTURE_BENCH_BASELINE` set to an earlier run's folder, each is
/// compared with that run's byte for byte, so a change to the texture pipeline can be shown to draw
/// the same pixels.
///
/// Only runs when asked: `OWE_TEXTURE_BENCH` (`TEST_RUNNER_OWE_TEXTURE_BENCH`) lists workshop ids in
/// the library (`OWE_LIBRARY`). `OWE_TEXTURE_BENCH_SIZE` is the drawable (default 1920x1080).
/// Particle systems are drawn unless `OWE_TEXTURE_BENCH_PARTICLES` is 0.
final class SceneTextureLoadBenchmarkTests: XCTestCase {
    private static let warmFrames = 150
    private static let comparedFrames = [0, 30, 59]
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-texture-bench-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testTextureLoadCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_TEXTURE_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_TEXTURE_BENCH to run the texture load benchmark")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let parts = (environment["OWE_TEXTURE_BENCH_SIZE"] ?? "1920x1080").split(separator: "x").compactMap { Int($0) }
        let drawable = SIMD2<Int>(parts.first ?? 1920, parts.last ?? 1080)
        let particles = environment["OWE_TEXTURE_BENCH_PARTICLES"] != "0"
        let output = environment["OWE_TEXTURE_BENCH_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let baseline = environment["OWE_TEXTURE_BENCH_BASELINE"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var report = ["Texture load: build ms (decode), take ms (upload), GPU MB held, footprint MB after build / after upload, "
                      + "frame GPU ms median; frames against the baseline"]
        for id in request.split(separator: ",").map(String.init) {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            let data = try XCTUnwrap(FileManager.default.contents(atPath: directory.appending(path: "project.json").path))
            let project = try JSONDecoder().decode(WEProject.self, from: data)
            defer { Fixtures.removeStoredSettings(for: directory) }
            let run = try measure(project, directory: directory, drawable: drawable, particles: particles)
            var line = String(format: "%@ %@: build %.1f ms, take %.1f ms, GPU %.1f MB, footprint %.1f / %.1f MB, frame GPU %.3f ms",
                              id, String(project.title.prefix(24)), run.buildMilliseconds, run.takeMilliseconds,
                              run.gpuMegabytes, run.footprintAfterBuild, run.footprintAfterTake, run.frameGPUMilliseconds)
            for (frame, pixels) in zip(Self.comparedFrames, run.frames) {
                let name = "\(id)-\(drawable.x)x\(drawable.y)-\(particles ? "p" : "np")-\(frame).rgba"
                if let output { try Data(pixels).write(to: output.appending(path: name)) }
                guard let baseline else { continue }
                let reference = try [UInt8](Data(contentsOf: baseline.appending(path: name)))
                let differing = Self.differingPixels(reference, pixels)
                line += differing == 0 ? " | frame \(frame) identical" : " | frame \(frame): \(differing) pixels differ"
                XCTAssertEqual(differing, 0, "\(id) frame \(frame) differs from the baseline")
            }
            report.append(line)
            print(line)
        }
        let text = report.joined(separator: "\n")
        print(text)
        if let output { try text.write(to: output.appending(path: "texture-report.txt"), atomically: true, encoding: .utf8) }
    }

    private struct Run {
        var buildMilliseconds = 0.0
        var takeMilliseconds = 0.0
        var gpuMegabytes = 0.0
        var footprintAfterBuild = 0.0
        var footprintAfterTake = 0.0
        var frameGPUMilliseconds = 0.0
        var frames: [[UInt8]] = []
    }

    private func measure(_ project: WEProject, directory: URL, drawable: SIMD2<Int>, particles: Bool) throws -> Run {
        var run = Run()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let buildStart = CACurrentMediaTime()
        let built = try XCTUnwrap(model.metalContent())
        run.buildMilliseconds = (CACurrentMediaTime() - buildStart) * 1000
        run.footprintAfterBuild = Self.footprintMegabytes()
        let content = particles ? built : Self.withoutParticles(built)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: drawable.x / 2, height: drawable.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: drawable.x, height: drawable.y)
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "texture-bench"))
        defer { renderer.releaseContent() }
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.scripts.frameWait = 5
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        let allocatedBefore = device.currentAllocatedSize
        let takeStart = CACurrentMediaTime()
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        run.takeMilliseconds = (CACurrentMediaTime() - takeStart) * 1000
        run.gpuMegabytes = (Double(device.currentAllocatedSize) - Double(allocatedBefore)) / 1_048_576
        run.footprintAfterTake = Self.footprintMegabytes()
        let viewport = SceneViewport(drawableSize: SIMD2(Float(drawable.x), Float(drawable.y)),
                                     pointSize: SIMD2(Float(drawable.x / 2), Float(drawable.y / 2)), cursor: nil,
                                     frameRateLimit: 60)
        var gpu: [Double] = []
        let last = Self.warmFrames + (Self.comparedFrames.max() ?? 0)
        for frame in 0...last {
            now += 1.0 / 60
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            // Pipelines compile off the render thread; give them the warm-up's time.
            RunLoop.main.run(until: Date().addingTimeInterval(frame < Self.warmFrames ? 0.01 : 0))
            guard frame >= Self.warmFrames else { continue }
            if let commandBuffer = renderer.lastCommandBuffer {
                gpu.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            }
            guard Self.comparedFrames.contains(frame - Self.warmFrames) else { continue }
            run.frames.append(try TextureUploadTests.read(try XCTUnwrap(renderer.sharedFrame), device: device))
        }
        run.frameGPUMilliseconds = gpu.isEmpty ? 0 : gpu.sorted()[gpu.count / 2]
        return run
    }

    /// The process's physical footprint (what Activity Monitor's Memory column shows), in MB.
    private static func footprintMegabytes() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) / 4 }
        var differing = 0
        for index in stride(from: 0, to: a.count, by: 4)
        where a[index] != b[index] || a[index + 1] != b[index + 1] || a[index + 2] != b[index + 2] || a[index + 3] != b[index + 3] {
            differing += 1
        }
        return differing
    }

    /// `content` without its particle systems.
    private static func withoutParticles(_ content: SceneMetalContent) -> SceneMetalContent {
        var copy = SceneMetalContent(size: content.size, layers: content.layers, particleSystems: [], bloom: content.bloom)
        copy.transforms = content.transforms
        copy.motions = content.motions
        copy.camera = content.camera
        copy.wallpaperKey = content.wallpaperKey
        copy.visibility = content.visibility
        copy.objectIDs = content.objectIDs
        copy.scripts = content.scripts
        copy.timelines = content.timelines
        copy.sounds = content.sounds
        copy.lighting = content.lighting
        copy.volumetrics = content.volumetrics
        copy.engineCombos = content.engineCombos
        copy.bloomChain = content.bloomChain
        copy.hdrChain = content.hdrChain
        return copy
    }
}
