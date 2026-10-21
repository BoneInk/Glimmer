import XCTest
import Metal
@testable import OpenWallpaperEngine

/// A particle object hidden and shown again (`ParticleFrameInputs.hidden`, WE's particle object
/// update `wallpaper64.exe` 0x140230650): the first hidden step with particles alive clears and
/// restarts the system, later hidden steps keep its time running with emission off, and it comes
/// back without a new pre-simulation.
final class ParticleHiddenObjectTests: XCTestCase {
    private static let step: Float = 1 / 64
    private var gpu: ParticleGPUStepper!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
    }

    private func runtime(_ system: ParticleTestSystem, startTime: Float = 0) throws -> ParticleSystemRuntime {
        var configuration = system.configuration
        configuration.startTime = startTime
        return ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration, seed: 5)
    }

    private func showStep(_ runtime: ParticleSystemRuntime) {
        for step in ParticlePrewarm.steps(runtime) {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: step, cursor: .zero))
        }
        gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: Self.step, cursor: .zero))
    }

    private func hideStep(_ runtime: ParticleSystemRuntime) {
        let inputs = ParticleFrameInputs.hidden(runtime, deltaTime: Self.step, holdsParticles: !gpu.particles(runtime).isEmpty)
        if let inputs { gpu.step(runtime, inputs: inputs) }
    }

    /// Hidden with particles alive: the first hidden step removes them and restarts the system's
    /// time and its emitters' clocks (0x1402306b5, 0x14022f6c0); the time then runs on while the
    /// clocks stand still (0x140230869 steps with emission off).
    func testHidingClearsOnceAndKeepsTheTimeRunningWithEmissionOff() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.emitterTiming.delay = 0.25
        let runtime = try runtime(system)
        for _ in 0..<64 { showStep(runtime) }
        XCTAssertGreaterThan(gpu.particles(runtime).count, 0)
        XCTAssertNotEqual(runtime.emitterStates[0], ParticleEmitterState())

        hideStep(runtime)
        XCTAssertTrue(gpu.particles(runtime).isEmpty)
        XCTAssertEqual(runtime.elapsedTime, Self.step, accuracy: 1e-6, "the restart zeroes the time before the step")
        XCTAssertEqual(runtime.emitterStates[0], ParticleEmitterState(), "every emitter is re-armed")
        XCTAssertTrue(runtime.clearedWhileHidden)

        for _ in 0..<31 { hideStep(runtime) }
        XCTAssertTrue(gpu.particles(runtime).isEmpty)
        XCTAssertEqual(runtime.elapsedTime, 32 * Self.step, accuracy: 1e-5)
        XCTAssertEqual(runtime.emitterStates[0], ParticleEmitterState(), "no emission: the clocks stand still")
    }

    /// Shown again, the system emits from its re-armed clocks: its `delay` runs again from the
    /// start, and there is no pre-simulation (WE's `starttime` runs only when the system is built).
    func testShownAgainTheSystemStartsOverWithoutAPresimulation() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 64
        system.lifetime = 10...10
        system.emitterTiming.delay = 0.25
        let runtime = try runtime(system, startTime: 2)
        showStep(runtime)
        XCTAssertGreaterThan(gpu.particles(runtime).count, 50, "the first frame pre-simulates two seconds")
        hideStep(runtime)
        hideStep(runtime)
        XCTAssertEqual(ParticlePrewarm.steps(runtime), [])

        // 0.25 s of delay, then 64 a second.
        for _ in 0..<12 { showStep(runtime) }
        XCTAssertTrue(gpu.particles(runtime).isEmpty, "the delay runs again")
        for _ in 0..<36 { showStep(runtime) }
        let particles = gpu.particles(runtime)
        let count = particles.count
        XCTAssertGreaterThanOrEqual(count, 30)
        XCTAssertLessThanOrEqual(count, 34)
        let oldest = particles.map(\.age).max() ?? 0
        XCTAssertLessThanOrEqual(oldest, 0.5 + 1e-4, "every particle spawned after the system was shown")
    }

    /// A system hidden from its first frame is never pre-simulated: WE built it with its
    /// pre-simulation, then cleared it on its first hidden step.
    func testASystemHiddenFromTheStartIsNotPresimulated() throws {
        let runtime = try runtime(ParticleTestSystem(), startTime: 1)
        XCTAssertFalse(ParticlePrewarm.steps(runtime).isEmpty)
        hideStep(runtime)
        XCTAssertEqual(ParticlePrewarm.steps(runtime), [])
        XCTAssertEqual(runtime.elapsedTime, Self.step, accuracy: 1e-6)
        showStep(runtime)
        XCTAssertLessThanOrEqual(gpu.particles(runtime).map(\.age).max() ?? 0, Self.step + 1e-5)
    }

    /// Hidden with nothing alive, the system isn't restarted (0x14023068e): its clocks keep where they
    /// stood and go on from there when shown.
    func testHidingAnEmptySystemKeepsItsClocks() throws {
        var system = ParticleTestSystem()
        system.emitterTiming.delay = 1
        let runtime = try runtime(system)
        for _ in 0..<16 { showStep(runtime) }
        XCTAssertTrue(gpu.particles(runtime).isEmpty)
        let clocks = runtime.emitterStates
        for _ in 0..<16 { hideStep(runtime) }
        XCTAssertEqual(runtime.emitterStates, clocks)
        XCTAssertEqual(runtime.elapsedTime, 0.5, accuracy: 1e-5)
        XCTAssertFalse(runtime.clearedWhileHidden)
    }
}
