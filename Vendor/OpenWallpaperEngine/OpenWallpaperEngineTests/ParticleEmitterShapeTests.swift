import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// The emitter's `instantaneous` burst and its shape: speed out from the centre, inner radius and
/// sign.
final class ParticleEmitterShapeTests: XCTestCase {
    private var gpu: ParticleGPUStepper!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
    }

    private func runtime(_ system: ParticleTestSystem) throws -> ParticleSystemRuntime {
        try runtime(system.configuration)
    }

    private func runtime(_ configuration: SceneMetalParticleSystem) throws -> ParticleSystemRuntime {
        ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration, seed: 9)
    }

    func testABurstSpawnsOnceWhenTheSystemStarts() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 40
        system.lifetime = 10...10
        let runtime = try runtime(system)
        gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(gpu.particles(runtime).count, 40, "a rate of 0 with a burst is not an idle system")
        for _ in 0..<30 { gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero) }
        XCTAssertEqual(gpu.particles(runtime).count, 40, "no second burst")
    }

    /// 3159348391's button symbols: a system with no rate and no burst, which only scripts'
    /// `emitParticles(1)` fills. What a script emits spawns and lives out its lifetime; the system
    /// isn't cleared as idle on the frames between.
    func testAScriptBurstIntoASystemWithoutARateLivesItsLifetime() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.lifetime = 0.5...0.5
        let runtime = try runtime(system)
        for _ in 0..<10 { gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero) }
        XCTAssertTrue(gpu.particles(runtime).isEmpty, "nothing emits on its own")

        var inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero)
        SceneMetalRenderer.applyScriptPlayback(nil, emitting: 3, to: &inputs)
        XCTAssertFalse(inputs.clears)
        gpu.step(runtime, inputs: inputs)
        XCTAssertEqual(gpu.particles(runtime).count, 3, "emitParticles(3)")
        // 0.4 s later the burst is still alive; past its 0.5 s lifetime it is gone.
        for _ in 0..<24 { gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero) }
        XCTAssertEqual(gpu.particles(runtime).count, 3, "the burst lives out its lifetime")
        for _ in 0..<12 { gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero) }
        XCTAssertTrue(gpu.particles(runtime).isEmpty, "and then dies")
    }

    func testABurstRespectsTheMaximum() throws {
        var system = ParticleTestSystem()
        system.instantaneous = 40
        system.maximum = 25
        let runtime = try runtime(system)
        gpu.update([runtime], deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(gpu.particles(runtime).count, 25)
    }

    /// `sphererandom` (wallpaper64.exe 0x140237c14): a radius between `distancemin` and
    /// `distancemax`, `sign` forcing an axis, speed out from the centre.
    func testEmitterSpeedPushesOutwardFromTheRing() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 200
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.emitterSpeed = SIMD2(100, 100)
        var configuration = system.configuration
        configuration.emitter.directions = SIMD3(1, 1, 0)
        configuration.emitter.distanceMinimum = SIMD3(repeating: 20)
        configuration.emitter.distanceMaximum = SIMD3(repeating: 40)
        configuration.emitter.sign = SIMD3(0, 1, 0)
        configuration.emitter.appliesSign = true
        let runtime = try runtime(configuration)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 0, cursor: .zero)
        gpu.step(runtime, inputs: inputs)
        let particles = gpu.particles(runtime)
        XCTAssertEqual(particles.count, 200)
        for particle in particles {
            let offset = particle.position - system.origin
            XCTAssertGreaterThanOrEqual(simd_length(offset), 20 - 1e-3, "inside distancemin")
            XCTAssertLessThanOrEqual(simd_length(offset), 40 + 1e-3)
            XCTAssertGreaterThanOrEqual(offset.y, 0, "sign forces y positive")
            XCTAssertEqual(simd_length(particle.velocity), 100, accuracy: 1e-2)
            XCTAssertGreaterThan(simd_dot(simd_normalize(particle.velocity), simd_normalize(offset)), 0.999)
        }
    }

    /// `boxrandom` (0x1401b9520): each axis between `distancemin` and `distancemax` from the
    /// centre, on a random side, `sign` forcing a side.
    func testBoxSpawnsInsideItsShell() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 300
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        var configuration = system.configuration
        configuration.emitter.kind = .box
        configuration.emitter.directions = SIMD3(1, 1, 0)
        configuration.emitter.distanceMinimum = SIMD3(10, 5, 0)
        configuration.emitter.distanceMaximum = SIMD3(60, 30, 0)
        configuration.emitter.sign = SIMD3(-1, 0, 0)
        configuration.emitter.appliesSign = true
        let runtime = try runtime(configuration)
        gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 0, cursor: .zero))
        let particles = gpu.particles(runtime)
        XCTAssertEqual(particles.count, 300)
        var sides = Set<Bool>()
        for particle in particles {
            let offset = particle.position - system.origin
            XCTAssertLessThanOrEqual(offset.x, -10 + 1e-3, "sign forces x negative, beyond distancemin")
            XCTAssertGreaterThanOrEqual(offset.x, -60 - 1e-3)
            XCTAssertGreaterThanOrEqual(abs(offset.y), 5 - 1e-3)
            XCTAssertLessThanOrEqual(abs(offset.y), 30 + 1e-3)
            sides.insert(offset.y > 0)
        }
        XCTAssertEqual(sides.count, 2, "an unsigned axis spawns on both sides")
    }
}
