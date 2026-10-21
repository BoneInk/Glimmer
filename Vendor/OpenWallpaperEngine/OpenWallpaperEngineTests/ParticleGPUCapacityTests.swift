import XCTest
@testable import OpenWallpaperEngine

/// P14: an instanced system's buffers are sized from what a step can spawn, not its whole budget.
final class ParticleGPUCapacityTests: XCTestCase {
    private func inputs(rate: Float, burst: Int = 0, instantaneous: Int = 0, deltaTime: Float = 1.0 / 60) -> ParticleFrameInputs {
        var inputs = ParticleFrameInputs()
        inputs.deltaTime = deltaTime
        inputs.emitters[0].rate = rate
        inputs.emitters[0].burst = burst
        inputs.emitters[0].instantaneous = instantaneous
        return inputs
    }

    func testPlainSystemBoundIsUnchanged() {
        // ⌊120 / 60⌋ + 1 + 5.
        XCTAssertEqual(ParticleGPUSystem.stepSpawns(inputs(rate: 120, burst: 5), instanceBursts: nil, slots: 1, maximumCount: 1000), 8)
        XCTAssertEqual(ParticleGPUSystem.stepSpawns(inputs(rate: 1e9), instanceBursts: nil, slots: 1, maximumCount: 50), 50)
    }

    func testInstancedBoundCountsEveryInstanceAndItsBurst() {
        // Each of 10 instances: ⌊60 / 60⌋ + 1 + a configured burst of 20.
        XCTAssertEqual(ParticleGPUSystem.stepSpawns(inputs(rate: 60), instanceBursts: [20], slots: 10, maximumCount: 100_000), 220)
        // An emitter the step doesn't list still bursts.
        XCTAssertEqual(ParticleGPUSystem.stepSpawns(inputs(rate: 0), instanceBursts: [0, 7], slots: 2, maximumCount: 100_000),
                       2 * (1 + 1 + 7))
        XCTAssertEqual(ParticleGPUSystem.stepSpawns(inputs(rate: 0), instanceBursts: [1_000], slots: 50, maximumCount: 4_000), 4_000)
    }

    func testCapacityGrowsAheadAndNeverPastAStep() {
        let first = ParticleGPUSystem.capacityPlan(held: 0, stepSpawns: 220, maximumCount: 100_000, capacity: 0)
        XCTAssertTrue(first.grows)
        XCTAssertGreaterThanOrEqual(first.capacity, 440, "a step ahead")
        XCTAssertLessThan(first.capacity, 100_000, "not the whole budget")
        // Room for this step and the next: no growth.
        XCTAssertFalse(ParticleGPUSystem.capacityPlan(held: 100, stepSpawns: 50, maximumCount: 1_000, capacity: 256).grows)
        // Capped at what one step can hold.
        let full = ParticleGPUSystem.capacityPlan(held: 1_000, stepSpawns: 100, maximumCount: 1_000, capacity: 1_000)
        XCTAssertTrue(full.grows)
        XCTAssertEqual(full.capacity, 1_100)
        XCTAssertEqual(ParticleGPUSystem.capacityPlan(held: 0, stepSpawns: 0, maximumCount: 0, capacity: 0).capacity, 256)
    }
}
