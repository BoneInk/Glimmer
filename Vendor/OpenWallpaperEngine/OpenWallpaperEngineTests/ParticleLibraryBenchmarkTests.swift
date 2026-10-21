import XCTest
import MetalKit
import simd
@testable import OpenWallpaperEngine

/// The per-frame cost of every library wallpaper's particle systems, the target of the particle
/// optimisation pass (all of a wallpaper's systems under 1 ms of GPU time at 1920×1080, the CPU
/// encode under 0.1 ms a system). Skipped without the library (`OWE_LIBRARY`); prints a table, and
/// writes it to `OWE_BENCH_OUT` when set (`TEST_RUNNER_OWE_BENCH_OUT` through xcodebuild);
/// `OWE_BENCH_ONLY` picks wallpapers, `OWE_BENCH_DETAIL` adds each system. GPU times are the least
/// of the measured frames: other work on the machine only ever adds to them.
///
/// - simulation: every system's GPU step in one command buffer, 1/60 s steps from a filled state,
///   as `ParticleGPUSimulator` runs it for the renderer: its GPU time, and the CPU time of the
///   frame's inputs and encode per system.
/// - frame: whole `SceneMetalRenderer` frames of the particle systems alone (drawn through their
///   materials) at 1920×1080, less a frame of an empty scene: GPU and CPU time.
final class ParticleLibraryBenchmarkTests: XCTestCase {
    private struct Row {
        var id: String
        var systems = 0
        var particles = 0
        var simulationGPU = 0.0
        var encodePerSystem = 0.0
        var frameGPU = 0.0
        var frameCPU = 0.0
    }

    func testLibraryParticleCost() throws {
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        let only = ProcessInfo.processInfo.environment["OWE_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        var rows: [Row] = []
        let baseline = try frameCost(device: device, content: nil)
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() where only?.contains(id) ?? true {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.appending(path: "scene.json").path),
                  let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data) else { continue } // decoding is covered elsewhere
            let identity = WallpaperSettingsIdentity.resolve(directory: directory)
            var keys: [String] = []
            for family in WallpaperSettingsIdentity.Family.allCases {
                keys.append(identity.key(family))
            }
            let hadSettings = keys.contains { UserDefaults.app.object(forKey: $0) != nil }
            defer {
                if !hadSettings { keys.forEach(UserDefaults.app.removeObject(forKey:)) }
            }
            guard let content = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent(),
                  !content.particleSystems.isEmpty else { continue }
            var row = Row(id: id, systems: content.particleSystems.count)
            try simulationCost(content, device: device, queue: queue, texture: texture, into: &row)
            let frame = try frameCost(device: device, content: content)
            row.frameGPU = max(frame.gpu - baseline.gpu, 0)
            row.frameCPU = max(frame.cpu - baseline.cpu, 0)
            rows.append(row)
            if ProcessInfo.processInfo.environment["OWE_BENCH_DETAIL"] != nil {
                // Each system without a parent drawn alone (with its children).
                for (index, system) in content.particleSystems.enumerated() where system.link == nil {
                    var family = [index]
                    for (child, candidate) in content.particleSystems.enumerated() where family.contains(candidate.link?.parentIndex ?? -1) {
                        family.append(child)
                    }
                    let alone = try frameCost(device: device, content: content, keeping: Set(family))
                    let plan = system.material
                    print(String(format: "  %@ #%d alone: frame gpu %.3f (%@, %@, blending %@, refract %@)", id, index,
                                 max(alone.gpu - baseline.gpu, 0), system.rendererName, plan?.shader ?? "built-in",
                                 system.blending, plan?.stages.contains(where: \.readsSceneSnapshot) == true ? "y" : "n"))
                }
            }
        }
        var lines = ["Particle cost per frame (ms; GPU the least of the frames, CPU the median): wallpaper, systems, particles, "
                     + "simulation GPU, CPU inputs and encode per system, frame GPU, frame CPU (1920x1080, less an empty frame)"]
        for row in rows {
            lines.append(String(format: "%@ %3d %7d  sim %.3f  enc/sys %.4f  frame gpu %.3f  cpu %.3f", row.id, row.systems,
                                row.particles, row.simulationGPU, row.encodePerSystem, row.frameGPU, row.frameCPU))
        }
        let worstGPU = rows.map(\.frameGPU).max() ?? 0, worstEncode = rows.map(\.encodePerSystem).max() ?? 0
        lines.append(String(format: "worst: frame GPU %.3f ms, encode per system %.4f ms; empty frame gpu %.3f cpu %.3f",
                            worstGPU, worstEncode, baseline.gpu, baseline.cpu))
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["OWE_BENCH_OUT"] {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private static func median(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    /// Every system's GPU step, one command buffer a frame.
    private func simulationCost(_ content: SceneMetalContent, device: MTLDevice, queue: MTLCommandQueue, texture: MTLTexture,
                                into row: inout Row) throws {
        let simulator = try ParticleGPUSimulator(device: device)
        let systems = content.particleSystems.enumerated().map { index, configuration in
            ParticleSystemRuntime(texture: texture, configuration: configuration, seed: ParticleRandom.pcg(UInt32(index)))
        }
        ParticleSystemRuntime.linkFamilies(systems)
        let cursor = content.size / 2
        var gpuTimes: [Double] = [], encodeTimes: [Double] = []
        for frame in 0..<240 {
            let start = CACurrentMediaTime()
            let requests = systems.map { system in
                ParticleGPUSimulator.Request(system: system, inputs: ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: cursor),
                                             kind: .fallback(rendererName: system.configuration.rendererName))
            }
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode(requests, sceneSize: content.size, targetSize: SIMD2(1920, 1080), commandBuffer: commandBuffer)
            commandBuffer.commit()
            let encode = CACurrentMediaTime() - start
            guard frame >= 180 else { continue }
            commandBuffer.waitUntilCompleted()
            gpuTimes.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            encodeTimes.append(encode * 1000 / Double(max(systems.count, 1)))
        }
        row.particles = systems.reduce(0) { $0 + ($1.gpu?.completedCount ?? 0) }
        row.simulationGPU = gpuTimes.min() ?? 0
        row.encodePerSystem = Self.median(encodeTimes)
        guard ProcessInfo.processInfo.environment["OWE_BENCH_DETAIL"] != nil else { return }
        // Each system in its own command buffer, in order: where the time goes.
        var perSystem = [[Double]](repeating: [], count: systems.count), perEncode = perSystem, perAdvance = perSystem
        for _ in 0..<30 {
            for (index, system) in systems.enumerated() {
                let start = CACurrentMediaTime()
                let inputs = ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: cursor)
                perAdvance[index].append((CACurrentMediaTime() - start) * 1000)
                let request = ParticleGPUSimulator.Request(system: system, inputs: inputs,
                                                           kind: .fallback(rendererName: system.configuration.rendererName))
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                simulator.encode([request], sceneSize: content.size, targetSize: SIMD2(1920, 1080), commandBuffer: commandBuffer)
                commandBuffer.commit()
                perEncode[index].append((CACurrentMediaTime() - start) * 1000)
                commandBuffer.waitUntilCompleted()
                perSystem[index].append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            }
        }
        for (index, system) in systems.enumerated() {
            let c = system.configuration
            let kinds = c.program.operators.map { "\($0.kind)" }.joined(separator: ",")
            let initializers = c.program.initializers.map { "\($0.kind)" }.joined(separator: ",")
            print(String(format: "  %@ #%d %@ max %d live %d instanced %@ gpu min %.3f enc %.3f (inputs %.3f) ops [%@] init [%@]",
                         row.id, index, c.rendererName, c.maximumParticleCount, system.gpu?.completedCount ?? 0,
                         c.isInstanced ? "y" : "n", perSystem[index].min() ?? 0, Self.median(perEncode[index]),
                         Self.median(perAdvance[index]), kinds, initializers))
        }
    }

    /// Whole frames of `content`'s particle systems alone (or of an empty scene) at 1920×1080.
    private func frameCost(device: MTLDevice, content: SceneMetalContent?, keeping: Set<Int>? = nil) throws -> (gpu: Double, cpu: Double) {
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1920, height: 1080)
        view.preferredFramesPerSecond = 60
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view))
        view.isPaused = true
        renderer.setPlacement(.stretch)
        let bloom = SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7, tint: SIMD3(repeating: 1))
        let size = content?.size ?? SIMD2(1920, 1080)
        var systems = content?.particleSystems ?? []
        if let keeping {
            // Children point at their parent by index: keep the family's order and renumber.
            let kept = systems.indices.filter { keeping.contains($0) }
            systems = kept.map { index in
                var system = systems[index]
                if let parent = system.link?.parentIndex { system.link?.parentIndex = kept.firstIndex(of: parent) ?? parent }
                return system
            }
        }
        var particles = SceneMetalContent(size: size, layers: [], particleSystems: systems, bloom: bloom)
        // Emitters hang off their objects as in the scene.
        particles.transforms = content?.transforms ?? .empty
        particles.motions = content?.motions ?? [:]
        renderer.setContent(particles)
        // The materials' pipelines, compiled once so the renderer's own compiles hit the caches.
        if let materials = ParticleMaterialRenderer(device: device) {
            for plan in (content?.particleSystems ?? []).compactMap(\.material) {
                XCTAssertTrue(materials.waitUntilCompiled(plan, pixelFormat: .bgra8Unorm))
            }
        }
        var gpu: [Double] = [], cpu: [Double] = []
        // Two seconds at the renderer's own clock fill the systems; then frames back to back, which
        // keep the GPU at speed.
        for frame in 0..<180 {
            if frame < 120 { RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60)) }
            let start = CACurrentMediaTime()
            renderer.draw(in: view)
            let elapsed = CACurrentMediaTime() - start
            guard let commandBuffer = renderer.lastCommandBuffer else { continue }
            commandBuffer.waitUntilCompleted()
            guard frame >= 120 else { continue }
            gpu.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
            cpu.append(elapsed * 1000)
        }
        if ProcessInfo.processInfo.environment["OWE_BENCH_DETAIL"] != nil {
            print(String(format: "  frame gpu min %.3f median %.3f max %.3f; cpu min %.3f median %.3f", gpu.min() ?? 0,
                         Self.median(gpu), gpu.max() ?? 0, cpu.min() ?? 0, Self.median(cpu)))
        }
        return (gpu.min() ?? 0, Self.median(cpu))
    }
}
