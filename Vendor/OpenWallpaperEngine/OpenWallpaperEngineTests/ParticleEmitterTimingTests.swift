import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Emitter `delay`, `duration`, random periodic emission and "limit to one per frame"
/// (`ParticleEmitterTiming`): the emitter clock, and the counts a GPU-simulated system holds;
/// `ParticleChildrenTests` covers them further.
final class ParticleEmitterTimingTests: XCTestCase {
    /// Exact in binary, so the phase boundaries fall on whole steps.
    private static let step: Float = 1 / 64

    // MARK: - Decoding

    func testTimingDecodesWithWEsDefaults() throws {
        // WE's thunderbolt beam: a delayed, one-second, periodic emitter that emits 8 a period.
        let beam = try emitter(#"{"delay": 0.2, "duration": 1, "flags": 4, "maxperiodicdelay": 9999, "maxperiodicduration": 1,"#
                               + #" "maxtoemitperperiod": 8, "minperiodicdelay": 9999, "minperiodicduration": 1, "rate": 100}"#)
        XCTAssertEqual(beam.delay, 0.2, accuracy: 1e-6)
        XCTAssertEqual(beam.duration, 1)
        XCTAssertTrue(beam.periodic)
        XCTAssertFalse(beam.onePerFrame)
        XCTAssertEqual(beam.periodDuration, 1...1)
        XCTAssertEqual(beam.periodDelay, 9999...9999)
        XCTAssertEqual(beam.maximumPerPeriod, 8)
        XCTAssertEqual(beam.periodLimit(countScale: 1.5), 12, "the limit scales with the count override")

        let plain = try emitter(#"{"flags": 2, "rate": 32}"#)
        var expected = ParticleEmitterTiming()
        expected.onePerFrame = true
        XCTAssertEqual(plain, expected)
        XCTAssertEqual(plain.periodDuration, 2...3, "an unset periodic range is 2…3 s emitting")
        XCTAssertEqual(plain.periodDelay, 1...2, "and 1…2 s paused")
        XCTAssertNil(plain.periodLimit(countScale: 1), "no limit unless periodic")
        let inverted = try emitter(#"{"flags": 4, "minperiodicduration": 5, "maxperiodicduration": 3}"#)
        XCTAssertEqual(inverted.periodDuration, 3...3, "a minimum above the maximum is lowered to it")
    }

    // MARK: - Children restarting with their parent

    /// Link flag 2: each period a periodic parent starts restarts the child's time and clocks
    /// (`wallpaper64.exe` 0x14022f790 → 0x14022f6c0); a child without it runs on.
    func testALinkFlag2ChildRestartsWithItsParentsPeriods() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        var parentSystem = ParticleTestSystem()
        parentSystem.emitterTiming.periodic = true
        parentSystem.emitterTiming.periodDuration = 0.5...0.5
        parentSystem.emitterTiming.periodDelay = 1...1
        func restarts(linked: Bool) -> Int {
            let parent = ParticleSystemRuntime(texture: texture, configuration: parentSystem.configuration)
            var configuration = ParticleTestSystem().configuration
            configuration.link = ParticleChildLink(parentIndex: 0, kind: .static,
                                                   local: SceneLocalTransform(origin: .zero, scale: SIMD2(1, 1), angle: 0),
                                                   probability: 1, maximumInstances: 1, instanced: false,
                                                   restartsWithParentPeriod: linked)
            let child = ParticleSystemRuntime(texture: texture, configuration: configuration)
            child.parent = parent
            var count = 0, last: Float = 0
            for _ in 0..<256 {
                _ = ParticleFrameInputs.advance(parent, deltaTime: Self.step, cursor: .zero)
                _ = ParticleFrameInputs.advance(child, deltaTime: Self.step, cursor: .zero)
                if child.elapsedTime < last { count += 1 }
                last = child.elapsedTime
            }
            return count
        }
        // Periods start at 0, 1.5 and 3 s; the one at 0 restarts a child that has just started.
        XCTAssertEqual(restarts(linked: true), 2)
        XCTAssertEqual(restarts(linked: false), 0)
    }

    // MARK: - Clock

    func testDelayHoldsTheBurstAndTheRate() {
        var timing = ParticleEmitterTiming()
        timing.delay = 0.5
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 60)
        let first = steps.firstIndex { $0.bursts }
        XCTAssertEqual(first, 31, "starts on the step that reaches 0.5 s")
        XCTAssertFalse(steps[..<31].contains { $0.emits || $0.bursts })
        XCTAssertTrue(steps[31...].allSatisfy(\.emits))
        XCTAssertEqual(steps.filter(\.bursts).count, 1)
    }

    func testDurationStopsTheRateButNotTheParticles() {
        var timing = ParticleEmitterTiming()
        timing.delay = 0.25
        timing.duration = 0.5
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 120)
        let emitting = steps.indices.filter { steps[$0].emits }
        XCTAssertEqual(emitting.first, 15)
        XCTAssertEqual(emitting.last, 46, "0.5 s after the delay")
        XCTAssertEqual(emitting.count, 32)
    }

    func testPeriodicEmissionAlternatesAndBurstsEachPeriod() {
        var timing = ParticleEmitterTiming()
        timing.periodic = true
        timing.periodDuration = 0.5...0.5
        timing.periodDelay = 0.25...0.25
        var clock = ParticleEmitterClock()
        let steps = run(&clock, timing, frames: 180)
        let bursts = steps.indices.filter { steps[$0].bursts }
        XCTAssertEqual(bursts, [0, 48, 96, 144], "a burst every 0.75 s")
        XCTAssertTrue(steps[0..<32].allSatisfy(\.emits))
        XCTAssertFalse(steps[32..<48].contains { $0.emits }, "paused for 0.25 s")
        XCTAssertEqual(steps.filter(\.startsPeriod).count, 4)
    }

    func testRandomPeriodsStayInTheirRanges() {
        var timing = ParticleEmitterTiming()
        timing.periodic = true
        timing.periodDuration = 0.2...0.6
        timing.periodDelay = 0.1...0.3
        var lengths: Set<Float> = []
        for phase in UInt32(0)..<40 {
            let length = ParticleEmitterClock.phaseLength(phase, timing: timing, seed: 7, key: 0)
            XCTAssertTrue((phase % 2 == 0 ? timing.periodDuration : timing.periodDelay).contains(length))
            lengths.insert(length)
        }
        XCTAssertGreaterThan(lengths.count, 30, "each phase draws its own length")
        XCTAssertNotEqual(ParticleEmitterClock.phaseLength(0, timing: timing, seed: 7, key: 1),
                          ParticleEmitterClock.phaseLength(0, timing: timing, seed: 7, key: 2), "instances differ")
    }

    // MARK: - Emission on the GPU

    func testAPeriodEmitsNoMoreThanItsLimit() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.maximum = 100
        system.lifetime = 10...10
        system.instantaneous = 2
        system.emitterTiming.periodic = true
        system.emitterTiming.periodDuration = 1...1
        system.emitterTiming.periodDelay = 1...1
        system.emitterTiming.maximumPerPeriod = 32
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        let counts = try stepGPU(runtime, frames: 150)
        XCTAssertEqual(counts[63], 34, "the burst and 32 from the rate in the first second")
        XCTAssertEqual(counts[127], 34, "then nothing while paused")
        XCTAssertEqual(counts[149], 68, "a new period bursts and emits its 32 again")
    }

    func testLimitToOnePerFrame() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 600
        system.lifetime = 10...10
        system.emitterTiming.onePerFrame = true
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        XCTAssertEqual(try stepGPU(runtime, frames: 30).last, 30, "one a step, however high the rate")
        XCTAssertLessThan(runtime.emissionRemainder, 1, "the excess isn't carried")
    }

    func testDelayedEmitterStartsWithItsBurst() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 0
        system.instantaneous = 5
        system.lifetime = 10...10
        system.emitterTiming.delay = 0.5
        let runtime = ParticleSystemRuntime(texture: texture(), configuration: system.configuration, seed: 3)
        let counts = try stepGPU(runtime, frames: 40)
        XCTAssertEqual(counts[30], 0)
        XCTAssertEqual(counts[31], 5)
        XCTAssertEqual(counts[39], 5)
    }

    // MARK: - Helpers

    private func emitter(_ json: String) throws -> ParticleEmitterTiming {
        ParticleEmitterTiming(try JSONDecoder().decode(WEParticleEmitter.self, from: Data(json.utf8)))
    }

    private func run(_ clock: inout ParticleEmitterClock, _ timing: ParticleEmitterTiming,
                     frames: Int) -> [ParticleEmitterClock.Step] {
        (0..<frames).map { _ in clock.advance(Self.step, timing: timing, seed: 1, key: 0) }
    }

    /// The live particles after each of `frames` GPU steps.
    private func stepGPU(_ runtime: ParticleSystemRuntime, frames: Int) throws -> [Int] {
        let gpu = try ParticleGPUStepper()
        return (0..<frames).map { _ in
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: Self.step, cursor: .zero))
            return gpu.particles(runtime).count
        }
    }

    private func texture() -> MTLTexture {
        let device = MTLCreateSystemDefaultDevice()!
        return device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                   mipmapped: false))!
    }
}
