import XCTest
import Metal
@testable import OpenWallpaperEngine

/// Extreme or malformed particle input stays bounded: huge and non-finite `count` overrides,
/// budget sums that would overflow, and child families that nest or fan out without end.
final class ParticleInputBoundsTests: XCTestCase {
    private func system(maximum: Int, count: Float) -> SceneMetalParticleSystem {
        var test = ParticleTestSystem()
        test.maximum = maximum
        var configuration = test.configuration
        configuration.overrides.count = count
        return configuration
    }

    // MARK: - Budget

    func testCapacityOfNonFiniteCountsStaysInRange() {
        for count: Float in [.infinity, .nan, 1e30, -.infinity] {
            let capacity = ParticleBudget.capacity(of: system(maximum: 100_000, count: count))
            XCTAssertTrue((0...Int.max / 2).contains(capacity), "count \(count): \(capacity)")
        }
        XCTAssertEqual(ParticleBudget.capacity(of: system(maximum: 100_000, count: .infinity)), Int.max / 2)
    }

    func testTotalsSaturateInsteadOfOverflowing() {
        XCTAssertEqual(ParticleBudget.total([1, 2, 3]), 6)
        XCTAssertEqual(ParticleBudget.total([Int.max / 2, Int.max / 2, Int.max / 2]), Int.max)
        XCTAssertEqual(ParticleBudget.total([]), 0)
        XCTAssertEqual(ParticleBudget.total([-5, 5]), 5, "negative capacities count as none")
    }

    func testApplyingABudgetToHugeSystemsScalesThemDown() throws {
        var systems = [system(maximum: 100_000, count: .infinity), system(maximum: 100_000, count: .infinity),
                       system(maximum: 100_000, count: .infinity)]
        let report = try XCTUnwrap(ParticleBudget.apply(10_000, to: &systems))
        XCTAssertEqual(report.authored, Int.max)
        XCTAssertLessThan(report.scale, 1)
    }

    // MARK: - Frame inputs

    func testAnInfiniteCountOverrideGivesABoundedMaximum() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
        for (count, expected) in [(Float.infinity, Int(UInt32.max)), (1e30, Int(UInt32.max)), (-1, 0)] {
            let runtime = ParticleSystemRuntime(texture: texture, configuration: system(maximum: 1000, count: count), seed: 1)
            let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero)
            XCTAssertEqual(inputs.maximum, expected, "count \(count)")
        }
    }

    func testAPeriodLimitWithAHugeCountIsBounded() {
        var timing = ParticleEmitterTiming()
        timing.periodic = true
        timing.maximumPerPeriod = 10
        XCTAssertEqual(timing.periodLimit(countScale: .infinity), Int(UInt32.max))
        XCTAssertEqual(timing.periodLimit(countScale: .nan), 0)
    }

    func testPrewarmOfAHugeStartTimeIsBounded() {
        XCTAssertEqual(ParticlePrewarm.steps(startTime: 3e38, maximum: 10).count, 10_000)
    }

    func testASpriteSheetWithAZeroFrameSizeStillHasAGrid() {
        let sheet = SpriteSheet(frames: 4, frameSize: SIMD2(0, 0), duration: 1, textureSize: SIMD2(256, 256))
        XCTAssertGreaterThanOrEqual(sheet.columns, 1)
        XCTAssertGreaterThanOrEqual(sheet.rows, 1)
    }

    // MARK: - Child families

    private func builder(_ systems: [String: WEParticleSystem], reports: @escaping (String) -> Void) -> ParticleFamilyBuilder {
        ParticleFamilyBuilder(load: { systems[$0] ?? WEParticleSystem() },
                              build: { _, _, _, _ in ParticleTestSystem().configuration },
                              report: reports)
    }

    private func decode(_ json: String) throws -> WEParticleSystem {
        try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
    }

    func testAFamilyThatFansOutStopsAtItsMemberLimit() throws {
        // Every level names the next one 8 times: 8^6 systems without a bound.
        var systems: [String: WEParticleSystem] = [:]
        for level in 0..<6 {
            let child = #"{"name": "l\#(level + 1).json"}"#
            systems["l\(level).json"] = try decode(#"{"children": [\#(Array(repeating: child, count: 8).joined(separator: ","))]}"#)
        }
        var reports: [String] = []
        let family = builder(systems) { reports.append($0) }
            .family("l0.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, ParticleFamilyBuilder.maximumMembers)
        XCTAssertFalse(reports.isEmpty)
        XCTAssertLessThanOrEqual(reports.count, ParticleFamilyBuilder.maximumDepth)
    }

    func testADeepChainStopsAtItsDepthLimit() throws {
        var systems: [String: WEParticleSystem] = [:]
        for level in 0..<40 {
            systems["d\(level).json"] = try decode(#"{"children": [{"name": "d\#(level + 1).json"}]}"#)
        }
        var reports: [String] = []
        let family = builder(systems) { reports.append($0) }
            .family("d0.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, ParticleFamilyBuilder.maximumDepth)
        XCTAssertEqual(reports.count, 1)
    }

    func testAnOrdinaryFamilyIsUntouched() throws {
        let systems = ["root.json": try decode(#"{"children": [{"name": "a.json"}, {"name": "b.json"}]}"#),
                       "a.json": try decode(#"{"children": [{"name": "c.json"}]}"#)]
        var reports: [String] = []
        let family = builder(systems) { reports.append($0) }
            .family("root.json", world: .identity, overrides: SceneParticleOverrides())
        XCTAssertEqual(family.count, 4)
        XCTAssertEqual(reports, [])
    }
}
