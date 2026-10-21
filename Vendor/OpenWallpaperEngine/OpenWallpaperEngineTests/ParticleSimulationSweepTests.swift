import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Every particle system of every scene in a local library, loaded as the app loads it and simulated
/// on the GPU: every step completes and every particle's position, size, alpha and colour stay
/// finite. Skipped when the library is absent (CI). `OWE_LIBRARY` overrides the library root.
final class ParticleSimulationSweepTests: XCTestCase {
    func testEveryLibraryParticleSystemSimulatesOnTheGPU() throws {
        let library = LibrarySweepTests.libraryRoot
        try XCTSkipUnless(FileManager.default.fileExists(atPath: library.path), "wallpaper library not present")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulator = try ParticleGPUSimulator(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))

        var systems = 0, children = 0, particles = 0
        var failures: [String] = []
        for id in try FileManager.default.contentsOfDirectory(atPath: library.path).sorted() {
            let directory = library.appending(path: id, directoryHint: .isDirectory)
            guard FileManager.default.fileExists(atPath: directory.appending(path: "scene.json").path),
                  let data = FileManager.default.contents(atPath: directory.appending(path: "project.json").path),
                  let project = try? JSONDecoder().decode(WEProject.self, from: data) else { continue } // decoding is covered elsewhere
            // Loading stores the wallpaper's settings: remove them unless the app had some (a user's).
            let identity = WallpaperSettingsIdentity.resolve(directory: directory)
            var keys: [String] = []
            for family in WallpaperSettingsIdentity.Family.allCases {
                keys.append(identity.key(family))
            }
            let hadSettings = keys.contains { UserDefaults.app.object(forKey: $0) != nil }
            defer {
                if !hadSettings { keys.forEach(UserDefaults.app.removeObject(forKey:)) }
            }
            guard let content = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent()
            else { continue }
            // Families step together, parents first, as the renderer steps them.
            let configurations = content.particleSystems
            let gpuSystems = configurations.enumerated().map { index, configuration in
                ParticleSystemRuntime(texture: texture, configuration: configuration, seed: ParticleRandom.pcg(UInt32(index)))
            }
            ParticleSystemRuntime.linkFamilies(gpuSystems)
            let cursor = content.size / 2
            var buffers: [MTLCommandBuffer] = []
            for _ in 0..<90 {
                let requests = gpuSystems.map { gpu in
                    ParticleGPUSimulator.Request(system: gpu, inputs: ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: cursor),
                                                 kind: .fallback(rendererName: gpu.configuration.rendererName))
                }
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                simulator.encode(requests, sceneSize: content.size, targetSize: content.size, commandBuffer: commandBuffer)
                commandBuffer.commit()
                buffers.append(commandBuffer)
            }
            buffers.last?.waitUntilCompleted()
            if let error = buffers.lazy.compactMap(\.error).first {
                failures.append("\(id): a step failed: \(error)")
                continue
            }
            for (index, configuration) in configurations.enumerated() {
                systems += 1
                if configuration.link != nil { children += 1 }
                let states = simulator.snapshot(gpuSystems[index], queue: queue)
                particles += states.count
                let label = "\(id) system \(index) (\(configuration.rendererName), max \(configuration.maximumParticleCount))"
                let broken = states.filter { state in
                    !(state.positionVelocity.x.isFinite && state.positionVelocity.y.isFinite && state.life.z.isFinite
                      && state.alphaRotation.x.isFinite && state.color.x.isFinite && state.color.y.isFinite
                      && state.color.z.isFinite && state.color.w.isFinite)
                }
                if !broken.isEmpty {
                    failures.append("\(label): \(broken.count) of \(states.count) particles not finite")
                }
            }
        }
        print("Particle simulation sweep: \(systems) systems (\(children) children), \(particles) GPU particles after 90 frames, \(failures.count) failures")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
