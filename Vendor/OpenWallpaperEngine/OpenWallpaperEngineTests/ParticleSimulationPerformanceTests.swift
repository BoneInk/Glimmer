import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Per-frame cost of the GPU particle simulation at 1k, 10k and 100k live particles: the step's
/// CPU encode time and GPU time. Prints the medians; the bounds only catch a pathological slowdown.
final class ParticleSimulationPerformanceTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var simulator: ParticleGPUSimulator!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        simulator = try ParticleGPUSimulator(device: device)
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// Movement, gravity, drag, turbulence, and size, alpha and colour over life: a common mix.
    private func typical(_ count: Int) -> ParticleTestSystem {
        var system = ParticleTestSystem()
        system.maximum = count
        // Fills the system in two frames, then replaces every death at once.
        system.emissionRate = Float(count) * 30
        system.lifetime = 2...3
        system.spawnExtent = SIMD2(800, 400)
        system.gravity = SIMD2(0, -50)
        system.drag = 0.2
        system.operators = [
            ParticleOperator(.turbulence, a: SIMD4(1, 1, 0, 0), b: SIMD4(0.005, 200, 400, 0.1)),
            ParticleOperator(.sizeChange, a: SIMD4(1, 0.2, 0, 1)),
            ParticleOperator(.alphaChange, a: SIMD4(1, 0, 0.5, 1)),
            ParticleOperator(.colorChange, a: SIMD4(1, 1, 1, 0), b: SIMD4(1, 0.5, 0.2, 0), c: SIMD4(0, 1, 0, 0)),
        ]
        return system
    }

    /// About 80 s in Debug, so it runs nightly and locally (`OWE_SLOW_TESTS=1`), not on every PR.
    func testSimulationCost() throws {
        try SlowTests.require()
        var report: [String] = []
        for count in [1_000, 10_000, 100_000] {
            report.append(try measure("typical", typical(count), count: count))
        }
        for count in [1_000, 10_000, 100_000] {
            var system = typical(count)
            system.operators.append(ParticleOperator(.boids, flags: 1, a: SIMD4(20, 80, 500, 0), b: SIMD4(5, 0.2, 0.1, 0)))
            report.append(try measure("boids", system, count: count, frames: count >= 100_000 ? 6 : 20))
        }
        print("Particle simulation cost per frame (median):\n" + report.joined(separator: "\n"))
    }

    /// Many small systems, as most wallpapers have: the GPU step's fixed cost per system and the CPU
    /// encode per system (inputs and encode), minimum over the frames (the least disturbed by other
    /// work on the machine).
    func testManySmallSystemsCost() throws {
        var report: [String] = []
        for systemCount in [1, 10, 30] {
            var system = typical(50)
            system.emissionRate = 100
            system.lifetime = 0.4...0.6
            let runtimes = (0..<systemCount).map {
                ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: UInt32($0))
            }
            var gpuTimes: [Double] = [], encodeTimes: [Double] = [], inputTimes: [Double] = []
            for frame in 0..<90 {
                let start = CACurrentMediaTime()
                let requests = runtimes.map {
                    ParticleGPUSimulator.Request(system: $0, inputs: ParticleFrameInputs.advance($0, deltaTime: 1 / 60, cursor: .zero),
                                                 kind: .sprite, materialVertexCount: 6)
                }
                let inputsDone = CACurrentMediaTime()
                let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
                simulator.encode(requests, sceneSize: SIMD2(1920, 1080), targetSize: SIMD2(1920, 1080), commandBuffer: commandBuffer)
                commandBuffer.commit()
                let encode = CACurrentMediaTime() - start
                commandBuffer.waitUntilCompleted()
                guard frame >= 30 else { continue }
                gpuTimes.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
                encodeTimes.append(encode * 1000 / Double(systemCount))
                inputTimes.append((inputsDone - start) * 1000 / Double(systemCount))
            }
            XCTAssertLessThan(gpuTimes.min() ?? 0, 100)
            func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
            report.append(String(format: "%2d systems: GPU min %.3f ms (%.4f a system) | CPU a system min %.4f median %.4f ms (inputs %.4f)",
                                 systemCount, gpuTimes.min() ?? 0, (gpuTimes.min() ?? 0) / Double(systemCount),
                                 encodeTimes.min() ?? 0, median(encodeTimes), median(inputTimes)))
        }
        print("Particle systems cost per frame:\n" + report.joined(separator: "\n"))
    }

    private func measure(_ label: String, _ system: ParticleTestSystem, count: Int, frames: Int = 30) throws -> String {
        let gpu = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 1)
        var encodeTimes: [Double] = [], gpuTimes: [Double] = []
        for frame in 0..<(frames + 3) {
            let encodeStart = CACurrentMediaTime()
            let inputs = ParticleFrameInputs.advance(gpu, deltaTime: 1 / 60, cursor: .zero)
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            simulator.encode([.init(system: gpu, inputs: inputs, kind: .sprite, materialVertexCount: 6)],
                             sceneSize: SIMD2(1920, 1080), targetSize: SIMD2(1920, 1080), commandBuffer: commandBuffer)
            commandBuffer.commit()
            let encodeTime = CACurrentMediaTime() - encodeStart
            commandBuffer.waitUntilCompleted()
            XCTAssertNil(commandBuffer.error)
            // The first frames fill the system and grow its buffers.
            guard frame >= 3 else { continue }
            encodeTimes.append(encodeTime * 1000)
            gpuTimes.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
        }
        XCTAssertEqual(gpu.gpu?.completedCount, count, label)
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        // A hang guard, not a budget: CI runners have a slow virtual GPU (121 ms seen for 100k boids).
        XCTAssertLessThan(median(gpuTimes), 2000, "\(label) \(count)")
        return String(format: "%@ %7d: GPU %7.3f ms (+ %.3f ms CPU encode)",
                      label, count, median(gpuTimes), median(encodeTimes))
    }
}
