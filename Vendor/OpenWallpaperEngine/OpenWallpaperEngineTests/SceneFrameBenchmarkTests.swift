import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// Whole frames of chosen library wallpapers, drawn by the renderer as the app draws them (layers,
/// effects, particles through their materials, scripts, the post-process), to find what makes a
/// wallpaper slow. Only runs when asked: `OWE_SCENE_BENCH` (`TEST_RUNNER_OWE_SCENE_BENCH` through
/// xcodebuild) lists workshop ids, or is `playlist:<name>` for a playlist of the app's; skipped
/// otherwise and without the library (`OWE_LIBRARY`).
///
/// Each wallpaper is drawn at every size of `OWE_SCENE_BENCH_SIZES` (default 1920x1080 and
/// 3840x2160, a 4K display at 2×, as a shared frame of that size: the scene target follows it,
/// `SceneRenderResolution`), as a whole, without its particle systems, with them alone, and under
/// each particle budget that thins it (`ParticleBudget`). A row gives the GPU time (the least of the
/// measured frames, and the median), the render thread's CPU time for `draw(in:)` (median; it
/// includes the wait for the script frame; its thread-CPU clock beside it leaves waits out) and the
/// script thread's frame (median), plus the load (content preparation, then until the renderer holds
/// it), the peak GPU allocation and process footprint. Written to `OWE_BENCH_OUT` when set, and as
/// JSON rows to `OWE_SCENE_BENCH_JSON`, for later runs to diff against.
final class SceneFrameBenchmarkTests: XCTestCase {
    private struct Measure {
        var gpuMin = 0.0
        var gpuMedian = 0.0
        var cpuMedian = 0.0
        var scriptMedian = 0.0
        var particleCapacity = 0
        var gpuMean = 0.0
        var gpuP99 = 0.0
        /// The render thread's own CPU time for `draw(in:)` (thread CPU clock, median), without waits.
        var threadCPUMedian = 0.0
        /// From `setContent` to the renderer holding the content (pipelines and textures ready).
        var firstFrameSeconds = 0.0
        var peakGPUAllocatedBytes = 0
        var peakFootprintBytes = 0
    }

    /// One row of `OWE_SCENE_BENCH_JSON`, for later runs to diff against.
    private struct Row: Encodable {
        let wallpaper: String
        let title: String
        let width: Int
        let height: Int
        let variant: String
        let contentSeconds: Double
        let firstFrameSeconds: Double
        let gpuMin: Double
        let gpuMedian: Double
        let gpuMean: Double
        let gpuP99: Double
        let cpuMedian: Double
        let threadCPUMedian: Double
        let scriptMedian: Double
        let effectMPix: Double
        let peakGPUAllocatedMB: Double
        let peakFootprintMB: Double
        let particleCapacity: Int
    }

    private enum Variant: CustomStringConvertible {
        case full, withoutParticles, particlesOnly, withoutEffects, budget(GSParticleBudget)
        /// The whole scene drawn with other render settings (`renderModes`).
        case render(String, SceneRenderSettings)

        var description: String {
            switch self {
            case .full: return "full"
            case .withoutParticles: return "no particles"
            case .particlesOnly: return "particles only"
            case .withoutEffects: return "no effects"
            case .budget(let budget): return "budget \(budget.rawValue)"
            case .render(let name, _): return name
            }
        }
    }

    /// The render settings `OWE_SCENE_BENCH_MODES` asks for, by name (comma separated): `half` (WE's
    /// texture reduction), `match` (Effect Detail Match Display), the render resolutions as the app
    /// draws them, without the authored-size floor (`yourdisplay`: the drawable's pixels, `uhd4k`:
    /// 4K at its shape, `authored`: Full, the scene's authored size), `scale50` (drawn at 50% and
    /// upscaled; `scale67`, `scale75` likewise), `textures` ("Optimise textures" on: BC7 colour images, `TexturePreparation`),
    /// the quality presets (`ultra`, `high`, `medium`, `low`), Ultra lowered on battery (`battery-medium`, …), and
    /// `+` joins them (`yourdisplay+scale50`). With the variable set, only these and `full` are drawn.
    /// `OWE_SCENE_BENCH_TEXTURES=1` adds the `textures` row to the default variants, so the rows
    /// show the setting off (`full`) and on.
    /// The settings a quality preset sets, by its name.
    private static func preset(_ name: String) -> GlobalSettings {
        let quality: GSQuality = switch name {
        case "low": .low
        case "medium": .medium
        case "high": .high
        default: .ultra
        }
        return GlobalSettingsViewModel.applying(quality, to: GlobalSettings())
    }

    private static func renderModes(_ request: String) -> [Variant] {
        request.split(separator: ",").map { name in
            var settings = SceneRenderSettings()
            settings.particleBudget = .unlimited
            for part in name.split(separator: "+") {
                switch part {
                case "half": settings.textureReduction = 2
                case "match": settings.sceneDetail = .matchDisplay
                case "yourdisplay":
                    settings.renderResolution = .yourDisplay
                    settings.floorsAtAuthoredSize = false
                case "uhd4k":
                    settings.renderResolution = .uhd4K
                    settings.floorsAtAuthoredSize = false
                case "authored":
                    settings.renderResolution = .full
                    settings.floorsAtAuthoredSize = false
                case "scale50", "scale67", "scale75":
                    settings.upscaling = .bilinear
                    settings.renderScale = part == "scale50" ? .percent50 : part == "scale67" ? .percent67 : .percent75
                case "textures": settings.optimiseTextures = true
                case "ultra", "high", "medium", "low":
                    // A quality preset as the app draws it (`GlobalSettingsViewModel.applying`).
                    settings = SceneRenderSettings(Self.preset(String(part)))
                case "battery-high", "battery-medium", "battery-low":
                    // Ultra lowered by "On battery: use a lower quality preset" (`BatteryQuality`).
                    var ultra = Self.preset("ultra")
                    ultra.batteryQuality = true
                    ultra.batteryQualityPreset = GSBatteryPreset(rawValue: String(part.dropFirst("battery-".count))) ?? .medium
                    settings = SceneRenderSettings(BatteryQuality.lowered(ultra))
                default: XCTFail("unknown render mode \(part)")
                }
            }
            return .render(String(name), settings)
        }
    }

    func testSceneFrameCost() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let request = environment["OWE_SCENE_BENCH"], !request.isEmpty else {
            throw XCTSkip("set OWE_SCENE_BENCH to run the scene benchmark")
        }
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-scene-bench-\(UUID().uuidString)")
        defer {
            do {
                if FileManager.default.fileExists(atPath: storage.path) { try FileManager.default.removeItem(at: storage) }
            } catch {
                XCTFail("Removing \(storage.path) failed: \(error)")
            }
        }
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let sizes = (environment["OWE_SCENE_BENCH_SIZES"] ?? "1920x1080,3840x2160").split(separator: ",").compactMap { entry -> SIMD2<Int>? in
            let parts = entry.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? SIMD2(parts[0], parts[1]) : nil
        }
        var lines = ["Scene frame cost (ms): GPU min / median / p99, render-thread wall and thread-CPU median, script median; "
                     + "load s (content, first frame), peak GPU allocation and footprint MB; particle capacity"]
        var rows: [Row] = []
        for directory in try Self.wallpapers(request, library: library) {
            guard let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data), // optional: not every folder is a wallpaper
                  project.type.lowercased() == "scene" else {
                lines.append("\(directory.lastPathComponent): not a scene; skipped")
                continue
            }
            let restore = Self.keepStoredSettings(directory: directory, projectData: data)
            defer { restore() }
            let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
            var unlimited = SceneRenderSettings()
            unlimited.particleBudget = .unlimited
            model.setRenderSettings(unlimited)
            let contentStart = CACurrentMediaTime()
            let prepared = model.metalContent()
            let contentSeconds: Double = CACurrentMediaTime() - contentStart
            guard let content = prepared else {
                lines.append("\(directory.lastPathComponent): no content")
                continue
            }
            let authored = content.particleSystems.reduce(0) { $0 + ParticleBudget.capacity(of: $1) }
            let refracting = content.particleSystems.filter { $0.material?.stages.contains(where: \.readsSceneSnapshot) == true }
            let effects = content.layers.reduce(0) { $0 + $1.weEffects.count }
            lines.append(String(format: "%@ “%@”: scene %.0fx%.0f, %d layers, %d effects, %d particle systems (%d refracting), %d particles authored",
                                directory.lastPathComponent, project.title, content.size.x, content.size.y, content.layers.count,
                                effects, content.particleSystems.count, refracting.count, authored))
            var variants: [Variant] = [.full]
            if let modes = environment["OWE_SCENE_BENCH_MODES"], !modes.isEmpty {
                variants += Self.renderModes(modes)
            } else {
                if effects > 0 { variants.append(.withoutEffects) }
            }
            if environment["OWE_SCENE_BENCH_TEXTURES"] == "1", environment["OWE_SCENE_BENCH_MODES"]?.isEmpty ?? true {
                variants += Self.renderModes("textures")
            }
            if environment["OWE_SCENE_BENCH_MODES"]?.isEmpty ?? true, !content.particleSystems.isEmpty {
                variants += [.withoutParticles, .particlesOnly]
                for budget in [GSParticleBudget.high, .medium, .low] where ParticleBudget.scale(authored: authored, budget: budget.limit) < 1 {
                    variants.append(.budget(budget))
                }
            }
            for size in sizes {
                for variant in variants {
                    var drawn = content
                    var settings = unlimited
                    switch variant {
                    case .full: break
                    case .render(_, let modeSettings):
                        settings = modeSettings
                        model.setRenderSettings(settings)
                        drawn = try XCTUnwrap(model.metalContent())
                        model.setRenderSettings(unlimited)
                    case .withoutEffects:
                        let plain = content.layers.map { layer -> SceneMetalLayer in
                            var layer = layer
                            layer.weEffects = []
                            return layer
                        }
                        drawn = Self.content(content, layers: plain, particleSystems: content.particleSystems)
                    case .withoutParticles: drawn = Self.content(content, layers: content.layers, particleSystems: [])
                    case .particlesOnly:
                        drawn = Self.content(content, layers: [], particleSystems: content.particleSystems)
                        drawn.scripts = nil
                    case .budget(let budget):
                        var settings = SceneRenderSettings()
                        settings.particleBudget = budget
                        model.setRenderSettings(settings)
                        drawn = try XCTUnwrap(model.metalContent())
                        model.setRenderSettings(unlimited)
                    }
                    let measure = try frameCost(drawn, size: size, settings: settings, device: device, services: services)
                    lines.append(String(format: "  %4dx%-4d %-16@ gpu %7.3f / %7.3f / %7.3f  cpu %6.3f (thread %6.3f)  script %6.3f  "
                                        + "load %.2f+%.2f s  gpu mem %.0f MB  footprint %.0f MB  particles %d",
                                        size.x, size.y, variant.description as NSString, measure.gpuMin, measure.gpuMedian,
                                        measure.gpuP99, measure.cpuMedian, measure.threadCPUMedian, measure.scriptMedian,
                                        contentSeconds, measure.firstFrameSeconds, Double(measure.peakGPUAllocatedBytes) / 1e6,
                                        Double(measure.peakFootprintBytes) / 1e6, measure.particleCapacity))
                    let effectMPix: Double = drawn.layers.reduce(0) { $0 + Self.effectPixels($1) } / 1e6
                    rows.append(Row(wallpaper: directory.lastPathComponent, title: project.title, width: size.x, height: size.y,
                                    variant: variant.description, contentSeconds: contentSeconds,
                                    firstFrameSeconds: measure.firstFrameSeconds, gpuMin: measure.gpuMin,
                                    gpuMedian: measure.gpuMedian, gpuMean: measure.gpuMean, gpuP99: measure.gpuP99,
                                    cpuMedian: measure.cpuMedian, threadCPUMedian: measure.threadCPUMedian,
                                    scriptMedian: measure.scriptMedian, effectMPix: effectMPix,
                                    peakGPUAllocatedMB: Double(measure.peakGPUAllocatedBytes) / 1e6,
                                    peakFootprintMB: Double(measure.peakFootprintBytes) / 1e6,
                                    particleCapacity: measure.particleCapacity))
                    print(lines.last!)
                }
            }
            // What each layer's effects shade a frame: every render pass's target, in megapixels. Frame
            // timings of one layer left out are too noisy with other GPU work on the machine; this isn't.
            var fills: [(pixels: Double, line: String)] = []
            for layer in content.layers where !layer.weEffects.isEmpty {
                let pixels = Self.effectPixels(layer)
                let files = layer.weEffects.map { ($0.file as NSString).deletingLastPathComponent.split(separator: "/").last.map(String.init) ?? $0.file }
                fills.append((pixels, String(format: "    layer %@ “%@” %@: %@, %d passes, %.1f MPix a frame", layer.id, layer.name,
                                             Self.inputSizeDescription(layer), files.joined(separator: ","),
                                             layer.weEffects.reduce(0) { $0 + $1.passes.count }, pixels / 1e6)))
            }
            let total = fills.reduce(0) { $0 + $1.pixels }
            lines.append(String(format: "  effects shade %.1f MPix a frame (a 3840x2160 target is 8.3)", total / 1e6))
            lines += fills.sorted { $0.pixels > $1.pixels }.prefix(6).map(\.line)
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = environment["OWE_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
        if let path = environment["OWE_SCENE_BENCH_JSON"], !path.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// The calling thread's CPU time so far, in milliseconds (its own work, not time spent waiting).
    static func threadCPUMilliseconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    /// The process's physical footprint (what Activity Monitor calls Memory), in bytes; 0 if unknown.
    static func processFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// The value at `fraction` (0…1) of `values` sorted; 0 for none.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded(.up)))
        return sorted[index]
    }

    /// The pixels `layer`'s effect passes render a frame: each render pass's target, the layer's
    /// input size or its FBO's (`EffectGraphRenderer.fboSize`).
    private static func effectPixels(_ layer: SceneMetalLayer) -> Double {
        let input = inputSize(layer)
        return layer.weEffects.reduce(0) { total, effect in
            let fbos = Dictionary(effect.fbos.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            return total + effect.passes.reduce(0) { sum, pass in
                guard case .render = pass.command else { return sum }
                let size = pass.target.flatMap { fbos[$0] }.map { EffectGraphRenderer.fboSize($0, width: input.x, height: input.y) } ?? input
                return sum + Double(size.x) * Double(size.y)
            }
        }
    }

    private static func inputSize(_ layer: SceneMetalLayer) -> SIMD2<Int> {
        let pixels = layer.source.pixelSize
        let size = pixels.x > 0 && pixels.y > 0 ? pixels : layer.size
        return SIMD2(Int(size.x.rounded()), Int(size.y.rounded()))
    }

    private static func inputSizeDescription(_ layer: SceneMetalLayer) -> String {
        let size = inputSize(layer)
        return "\(size.x)x\(size.y)"
    }

    /// `content` with other layers and particle systems.
    private static func content(_ content: SceneMetalContent, layers: [SceneMetalLayer],
                                particleSystems: [SceneMetalParticleSystem]) -> SceneMetalContent {
        var copy = SceneMetalContent(size: content.size, layers: layers, particleSystems: particleSystems, bloom: content.bloom)
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

    /// `OWE_SCENE_BENCH_PASSES`: the effect passes of 10 more frames, timed each (`EffectPassTimer`);
    /// the costliest, by their least time, are printed.
    private func printPasses(_ renderer: SceneMetalRenderer, viewport: SceneViewport) throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        guard let timer = EffectPassTimer(device: device) else { return print("    (no stage-boundary timestamps)") }
        renderer.effectPassTimer = timer
        defer { renderer.effectPassTimer = nil }
        var least: [String: (nanoseconds: Double, pixels: Int)] = [:]
        let start = (gpu: device.sampleTimestamps().gpu, wall: CACurrentMediaTime())
        var frames: [[EffectPassTimer.Sample]] = []
        for _ in 0..<10 {
            timer.reset()
            renderer.renderShared([viewport])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            let rate = EffectPassTimer.tickRate(from: start.gpu, to: device.sampleTimestamps().gpu,
                                                wallSeconds: CACurrentMediaTime() - start.wall)
            frames.append(timer.samples(ticksPerNanosecond: rate))
        }
        for sample in frames.joined() {
            let known = least[sample.label]
            if known == nil || sample.nanoseconds < known!.nanoseconds { least[sample.label] = (sample.nanoseconds, sample.pixels) }
        }
        let total = least.values.reduce(0) { $0 + $1.nanoseconds } / 1e6
        print(String(format: "    effect passes: %d, %.3f ms summed (least of 10 frames each; passes overlap)", least.count, total))
        for (label, value) in least.sorted(by: { $0.value.nanoseconds > $1.value.nanoseconds }).prefix(12) {
            print(String(format: "      %7.3f ms  %5.1f MPix  %@", value.nanoseconds / 1e6, Double(value.pixels) / 1e6, label))
        }
    }

    /// The wallpapers `request` names: workshop ids, or `playlist:<name>` for a playlist's scenes.
    private static func wallpapers(_ request: String, library: URL) throws -> [URL] {
        guard request.hasPrefix("playlist:") else {
            return request.split(separator: ",").map { library.appending(path: String($0), directoryHint: .isDirectory) }
        }
        let name = String(request.dropFirst("playlist:".count))
        // Reads the user's REAL playlists on purpose (the "Test Wallpapers" benchmark), read-only:
        // the test host's own defaults are an isolated suite (`AppStorageLocation`). Never write here.
        let data = try XCTUnwrap(CFPreferencesCopyAppValue("WallpaperPlaylists" as CFString,
                                                           AppStorageLocation.realBundleIdentifier as CFString) as? Data,
                                 "no playlists stored")
        struct Playlist: Decodable {
            struct Item: Decodable {
                struct Wallpaper: Decodable { let wallpaperDirectory: URL }
                let wallpaper: Wallpaper
            }
            let name: String
            let items: [Item]
        }
        let playlist = try XCTUnwrap(try JSONDecoder().decode([Playlist].self, from: data).first { $0.name == name },
                                     "no playlist \(name)")
        return playlist.items.map(\.wallpaper.wallpaperDirectory)
    }

    /// Loading a wallpaper stores its settings; this puts back what was stored before (nothing, for a
    /// wallpaper never opened), so the benchmark leaves the user's settings as they were.
    private static func keepStoredSettings(directory: URL, projectData: Data) -> () -> Void {
        let identity = WallpaperSettingsIdentity.resolve(directory: directory)
        var keys: [String] = []
        for family in WallpaperSettingsIdentity.Family.allCases {
            keys.append(identity.key(family))
        }
        let before = keys.map { UserDefaults.app.object(forKey: $0) }
        return {
            for (key, value) in zip(keys, before) {
                if let value { UserDefaults.app.set(value, forKey: key) } else { UserDefaults.app.removeObject(forKey: key) }
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// Frames of `content` at `size`: two and a half seconds at 60 fps to load, compile and fill,
    /// then 60 frames back to back.
    private func frameCost(_ content: SceneMetalContent, size: SIMD2<Int>, settings: SceneRenderSettings,
                           device: MTLDevice, services: SceneScriptServices) throws -> Measure {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: size.x / 2, height: size.y / 2), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: size.x, height: size.y)
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: services, screenID: "bench"))
        view.isPaused = true
        renderer.setPlacement(.fill)
        renderer.renderSettings = settings
        let loadStart = CACurrentMediaTime()
        renderer.setContent(content)
        defer { renderer.releaseContent() }
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
        let firstFrameSeconds: Double = CACurrentMediaTime() - loadStart
        if let materials = ParticleMaterialRenderer(device: device) {
            for plan in content.particleSystems.compactMap(\.material) {
                _ = materials.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm)
            }
        }
        let viewport = SceneViewport(drawableSize: SIMD2(Float(size.x), Float(size.y)),
                                     pointSize: SIMD2(Float(size.x / 2), Float(size.y / 2)), cursor: nil, frameRateLimit: 30)
        var gpu: [Double] = [], cpu: [Double] = [], threadCPU: [Double] = [], script: [Double] = []
        var peakAllocated = 0, peakFootprint = 0
        for frame in 0..<210 {
            if frame < 150 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) } else { RunLoop.main.run(until: Date()) }
            let scriptFrames = renderer.scripts.wallpaper?.frameTiming.frames ?? 0
            let start = CACurrentMediaTime()
            let threadStart = Self.threadCPUMilliseconds()
            // The frame a display (or the displays of a shared wallpaper) shows, at the asked size: an
            // offscreen view's drawable can fall back to its bounds' size, one pixel per point.
            renderer.renderShared([viewport])
            let elapsed = CACurrentMediaTime() - start
            let threadElapsed: Double = Self.threadCPUMilliseconds() - threadStart
            peakAllocated = max(peakAllocated, device.currentAllocatedSize)
            peakFootprint = max(peakFootprint, Self.processFootprint())
            guard let commandBuffer = renderer.lastCommandBuffer else { continue }
            commandBuffer.waitUntilCompleted()
            renderer.scripts.wallpaper?.waitUntilIdle()
            guard frame >= 150 else { continue }
            gpu.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            cpu.append(elapsed * 1000)
            threadCPU.append(threadElapsed)
            if let timing = renderer.scripts.wallpaper?.frameTiming, timing.frames > scriptFrames {
                script.append(timing.recentMilliseconds.last ?? 0)
            }
        }
        if ProcessInfo.processInfo.environment["OWE_SCENE_BENCH_PASSES"] != nil { try printPasses(renderer, viewport: viewport) }
        let capacity = content.particleSystems.reduce(0) { total, system in
            total + Int((Float(ParticleBudget.capacity(of: system)) * system.budgetScale).rounded())
        }
        return Measure(gpuMin: gpu.min() ?? 0, gpuMedian: Self.median(gpu), cpuMedian: Self.median(cpu),
                       scriptMedian: Self.median(script), particleCapacity: capacity,
                       gpuMean: gpu.isEmpty ? 0 : gpu.reduce(0, +) / Double(gpu.count), gpuP99: Self.percentile(gpu, 0.99),
                       threadCPUMedian: Self.median(threadCPU), firstFrameSeconds: firstFrameSeconds,
                       peakGPUAllocatedBytes: peakAllocated, peakFootprintBytes: peakFootprint)
    }
}

/// The benchmark's measuring helpers, which run without the library.
final class SceneFrameBenchmarkHelperTests: XCTestCase {
    func testPercentileAndCounters() {
        let values: [Double] = (1...100).map(Double.init)
        let p99: Double = SceneFrameBenchmarkTests.percentile(values, 0.99)
        XCTAssertEqual(p99, 100)
        let none: Double = SceneFrameBenchmarkTests.percentile([], 0.5)
        XCTAssertEqual(none, 0)
        let footprint: Int = SceneFrameBenchmarkTests.processFootprint()
        XCTAssertGreaterThan(footprint, 0)
        let before: Double = SceneFrameBenchmarkTests.threadCPUMilliseconds()
        var sum = 0.0
        for index in 0..<2_000_000 { sum += Double(index).squareRoot() }
        XCTAssertGreaterThan(sum, 0)
        let after: Double = SceneFrameBenchmarkTests.threadCPUMilliseconds()
        XCTAssertGreaterThan(after, before)
    }
}
