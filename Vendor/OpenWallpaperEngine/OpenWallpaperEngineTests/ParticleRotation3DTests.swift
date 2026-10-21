import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Particle rotation in 3D (test-risks PG1, we-values-audit notes §11): WE keeps a particle's rotation
/// and angular velocity per axis (system+0x280, +0x288, +0x290 and +0x298, +0x2a0, +0x2a8).
/// `rotationrandom` and `angularvelocityrandom` draw every axis (0x14023bf55…0x14023bffb,
/// 0x14023c3d5…0x14023c4c3), `angularmovement` spins each with its own force (0x14023ffc7), and
/// `genericparticle.vert` turns the quad by all three (`ComputeParticleTangents`). The remap
/// outputs stay on z (0x14023dd8e, 0x14023de1b).
final class ParticleRotation3DTests: XCTestCase {
    private var gpu: ParticleGPUStepper!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
    }

    /// One particle at rest with `initializers` and `operators` (no other rotation), after a step
    /// of `age` seconds past its spawn.
    private func particle(initializers: [ParticleInitializer], operators: [ParticleOperator] = [],
                          age: Float = 0) throws -> ParticleGPUState {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 1
        system.maximum = 1
        system.spawnExtent = .zero
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.lifetime = 10...10
        system.rotation = 0...0
        system.angularVelocity = 0...0
        system.spins = false
        system.initializers = initializers
        system.operators = operators
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: system.configuration, seed: 3)
        gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 0, cursor: .zero))
        // A frame time of 25 ms or less leaves the drag undamped (`ParticleFrameInputs.dragDeltaTime`).
        if age > 0 { gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: age, cursor: .zero,
                                                                           frameTime: 0.025)) }
        return try XCTUnwrap(gpu.particles(runtime).first)
    }

    func testTheInitializersSetEveryAxis() throws {
        let rotation = ParticleInitializer(.rotationRandom, a: SIMD4(0.1, 0.2, 0.3, 1), b: SIMD4(0.1, 0.2, 0.3, 0))
        let spin = ParticleInitializer(.angularVelocityRandom, a: SIMD4(1, -2, 3, 1), b: SIMD4(1, -2, 3, 0))
        let p = try particle(initializers: [rotation, spin])
        XCTAssertEqual(p.rotationXY.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(p.rotationXY.y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(p.rotation, 0.3, accuracy: 1e-6)
        XCTAssertEqual(p.angularVelocityXY.x, 1, accuracy: 1e-6)
        XCTAssertEqual(p.angularVelocityXY.y, -2, accuracy: 1e-6)
        XCTAssertEqual(p.angularVelocity, 3, accuracy: 1e-6)
    }

    /// `angularmovement`: per axis, ω += force·dt; rotation += ω·dt; ω ×= 1 − min(drag·dt, 1).
    func testAngularMovementSpinsEachAxis() throws {
        let start = ParticleInitializer(.angularVelocityRandom, a: SIMD4(1, 1, 1, 1), b: SIMD4(1, 1, 1, 0))
        let move = ParticleOperator(.angularMovement, a: SIMD4(2, -4, 6, 0.5))
        let p = try particle(initializers: [start], operators: [move], age: 0.5)
        let spin = SIMD3<Float>(1 + 2 * 0.5, 1 - 4 * 0.5, 1 + 6 * 0.5)
        XCTAssertEqual(p.rotationXY.x, spin.x * 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.rotationXY.y, spin.y * 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.rotation, spin.z * 0.5, accuracy: 1e-5)
        XCTAssertEqual(p.angularVelocityXY.x, spin.x * 0.75, accuracy: 1e-5)
        XCTAssertEqual(p.angularVelocityXY.y, spin.y * 0.75, accuracy: 1e-5)
        XCTAssertEqual(p.angularVelocity, spin.z * 0.75, accuracy: 1e-5)
    }

    /// A system whose rotations have no x or y (every 2D preset) draws exactly as before: the
    /// records' rotation is (0, 0, z).
    func testAFlatSystemKeepsFlatRecords() throws {
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: ParticleTestSystem().configuration, seed: 3)
        for _ in 0..<30 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
        }
        let particles = gpu.particles(runtime)
        XCTAssertGreaterThan(particles.count, 10)
        XCTAssertTrue(particles.allSatisfy { $0.rotationXY == .zero && $0.angularVelocityXY == .zero })
        XCTAssertTrue(particles.contains { $0.rotation != 0 })
    }

    /// Random rotations and spins about x and y, driven by `angularmovement`, turn the particles
    /// about x and y.
    func testTheParticlesSpinAboutEveryAxis() throws {
        var system = ParticleTestSystem()
        system.spins = false
        system.initializers = [ParticleInitializer(.rotationRandom, a: SIMD4(-1, 0.5, 0, 1), b: SIMD4(1, 1.5, 0, 0)),
                               ParticleInitializer(.angularVelocityRandom, a: SIMD4(0.5, -3, 0, 1), b: SIMD4(1.5, -1, 0, 0))]
        system.operators = [ParticleOperator(.angularMovement, a: SIMD4(2, -1, 0.5, 0.2))]
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: system.configuration, seed: 11)
        for _ in 0..<60 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
        }
        let states = gpu.particles(runtime)
        XCTAssertGreaterThan(states.count, 50)
        let total: SIMD4<Float> = states.map(\.spin).reduce(SIMD4<Float>.zero, +)
        let mean: SIMD4<Float> = total / Float(max(states.count, 1))
        XCTAssertGreaterThan(abs(mean.x) + abs(mean.w), 0.5, "the particles turn about x and y: \(mean)")
    }
}
