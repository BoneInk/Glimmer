import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// The simulation's seeding, random draws, emission cap and boids on a plain system.
final class ParticleSimulationBasicsTests: XCTestCase {
    private var gpu: ParticleGPUStepper!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
        texture = try gpu.texture()
    }

    private func run(_ system: ParticleTestSystem, seed: UInt32, frames: Int = 60) -> [ParticleGPUState] {
        let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: seed)
        for _ in 0..<frames {
            gpu.update([runtime], deltaTime: 1 / 60, cursor: SIMD2(100, 100))
        }
        return gpu.particles(runtime).sorted { $0.serial < $1.serial }
    }

    func testTheSameSeedReplaysTheSameParticles() {
        var system = ParticleTestSystem()
        system.operators = [ParticleOperator(.turbulence, a: SIMD4(1, 1, 0, 0), b: SIMD4(0.01, 100, 300, 1))]
        let first = run(system, seed: 7), second = run(system, seed: 7), other = run(system, seed: 8)
        XCTAssertGreaterThan(first.count, 100)
        XCTAssertEqual(first.map(\.position), second.map(\.position))
        XCTAssertEqual(first.map(\.color), second.map(\.color))
        XCTAssertNotEqual(first.map(\.position), other.map(\.position))
    }

    func testRandomDrawsAreUniformAndStayInRange() {
        var sum: Float = 0
        for serial in UInt32(0)..<10_000 {
            let value = ParticleRandom.value(2, 4, seed: 3, serial: serial, .spawnAngle)
            XCTAssertTrue((2..<4).contains(value))
            sum += value
        }
        XCTAssertEqual(sum / 10_000, 3, accuracy: 0.03)
        XCTAssertEqual(ParticleRandom.value(5, 1, seed: 0, serial: 0, .spawnAngle) <= 5, true, "reversed bounds don't trap")
    }

    func testEmissionFillsTheAuthoredMaximumAndNoMore() {
        var system = ParticleTestSystem()
        system.emissionRate = 100_000
        system.maximum = 25_000
        system.lifetime = 100...100
        XCTAssertEqual(run(system, seed: 1, frames: 30).count, 25_000)
    }

    func testBoidsSteerLargeSystems() {
        // Boids used to switch off above 1 500 particles.
        var system = ParticleTestSystem()
        system.emissionRate = 200_000
        system.maximum = 3_000
        system.lifetime = 100...100
        system.minimumVelocity = SIMD2(-50, -50)
        system.maximumVelocity = SIMD2(50, 50)
        let plain = run(system, seed: 2, frames: 40)
        // WE updates one slice of N/200 + 1 each frame, with the weights scaled to match.
        system.operators = [ParticleOperator(.boids, flags: 0, a: SIMD4(20, 500, 500, 0), b: SIMD4(0, 2, 0, 0))]
        let flocking = run(system, seed: 2, frames: 40)
        XCTAssertEqual(flocking.count, 3_000)
        func spread(_ particles: [ParticleGPUState]) -> Float {
            let mean = particles.reduce(SIMD2<Float>.zero) { $0 + $1.velocity } / Float(particles.count)
            return particles.reduce(Float(0)) { $0 + simd_length($1.velocity - mean) } / Float(particles.count)
        }
        XCTAssertLessThan(spread(flocking), spread(plain) * 0.8, "alignment pulls velocities together")
    }
}
