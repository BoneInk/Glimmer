import XCTest
import simd
import Metal
@testable import OpenWallpaperEngine

/// The user's particle budget (`ParticleBudget`): a scene authored with more particles than it
/// allows is thinned, every system by the same factor on its maximum and rate; a scene within it is
/// left as authored.
final class ParticleBudgetTests: XCTestCase {
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        texture = try XCTUnwrap(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)))
    }

    /// A system whose emission fills its maximum (lifetime 1…2 s).
    private func system(maximum: Int, rate: Float = 100_000) -> SceneMetalParticleSystem {
        var test = ParticleTestSystem()
        test.maximum = maximum
        test.emissionRate = rate
        return test.configuration
    }

    func testAScaleFitsTheAuthoredCountIntoTheBudget() {
        XCTAssertEqual(ParticleBudget.scale(authored: 40_000, budget: 10_000), 0.25)
        XCTAssertEqual(ParticleBudget.scale(authored: 10_000, budget: 10_000), 1, "exactly the budget fits")
        XCTAssertEqual(ParticleBudget.scale(authored: 90_000, budget: nil), 1, "unlimited")
        XCTAssertEqual(ParticleBudget.scale(authored: 0, budget: 10_000), 1)
    }

    func testEverySystemIsScaledByTheSameFactor() throws {
        var systems = [system(maximum: 30_000), system(maximum: 10_000, rate: 40_000)]
        let report = try XCTUnwrap(ParticleBudget.apply(20_000, to: &systems))
        XCTAssertEqual(report, ParticleBudget.Report(authored: 40_000, budget: 20_000, scale: 0.5))
        XCTAssertEqual(systems.map(\.budgetScale), [0.5, 0.5])
        // The authored values stay; the simulations read the factor through the frame's inputs.
        XCTAssertEqual(systems.map(\.maximumParticleCount), [30_000, 10_000])
        let inputs = systems.map { configuration in
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 1)
            return ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero)
        }
        XCTAssertEqual(inputs.map(\.maximum), [15_000, 5_000])
        XCTAssertEqual(inputs.map(\.emissionRate), [50_000, 20_000])
    }

    func testASceneWithinTheBudgetIsUntouched() {
        var systems = [system(maximum: 8_000), system(maximum: 2_000)]
        XCTAssertNil(ParticleBudget.apply(10_000, to: &systems))
        XCTAssertNil(ParticleBudget.apply(nil, to: &systems))
        XCTAssertEqual(systems.map(\.budgetScale), [1, 1])
        let runtime = ParticleSystemRuntime(texture: texture, configuration: systems[0], seed: 1)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero)
        XCTAssertEqual(inputs.maximum, 8_000)
        XCTAssertEqual(inputs.emissionRate, 100_000)
    }

    /// Instanced children hold their maximum per instance; the `count` override multiplies the
    /// maximum unless the system's flags switch it off.
    func testChildrenInstancesAndTheCountOverrideAreCounted() throws {
        var root = system(maximum: 1_000)
        root.overrides.count = 2
        var follow = system(maximum: 100)
        follow.link = ParticleChildLink(parentIndex: 0, kind: .follow, local: SceneLocalTransform(origin: .zero, scale: SIMD2(1, 1), angle: 0), probability: 1,
                                        maximumInstances: 30, instanced: true)
        var ignoring = system(maximum: 500)
        ignoring.overrides.count = 4
        ignoring.ignoredOverrides = .count
        ignoring.link = ParticleChildLink(parentIndex: 0, kind: .static, local: SceneLocalTransform(origin: .zero, scale: SIMD2(1, 1), angle: 0), probability: 1,
                                          maximumInstances: 1, instanced: false)
        XCTAssertEqual(ParticleBudget.capacity(of: root), 2_000)
        XCTAssertEqual(ParticleBudget.capacity(of: follow), 3_000)
        XCTAssertEqual(ParticleBudget.capacity(of: ignoring), 500)
        var systems = [root, follow, ignoring]
        let report = try XCTUnwrap(ParticleBudget.apply(1_100, to: &systems))
        XCTAssertEqual(report.authored, 5_500)
        XCTAssertEqual(report.scale, 0.2, accuracy: 1e-6)
        XCTAssertEqual(systems.map(\.budgetScale), Array(repeating: report.scale, count: 3))
        // The budget thins a system whose flags ignore the count override too.
        let runtime = ParticleSystemRuntime(texture: texture, configuration: systems[2], seed: 1)
        XCTAssertEqual(ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero).maximum, 100)
    }

    /// A `maxcount` far above what the emitters keep alive counts only what they keep alive: rate
    /// times the longest lifetime (with the overrides), one for the carried fraction, and bursts.
    func testAMaximumTheEmittersNeverReachCountsWhatTheyKeepAlive() {
        var rain = system(maximum: 100_000, rate: 400)
        XCTAssertEqual(ParticleBudget.capacity(of: rain), 801, "400 a second for up to 2 s, plus 1")
        rain.overrides.count = 5
        rain.overrides.lifetime = 0.5
        rain.overrides.rate = 2
        rain.instantaneous = 50
        XCTAssertEqual(ParticleBudget.capacity(of: rain), 2_051, "2 000 a second (the count scales the rate; the rate override doesn't) for up to 1 s, plus 1 and the burst")
        rain.extraEmitters = [ParticleEmitter(rate: 100)]
        XCTAssertEqual(ParticleBudget.capacity(of: rain), 2_552)
        var systems = [rain, system(maximum: 5_000)]
        XCTAssertNil(ParticleBudget.apply(10_000, to: &systems), "7 552 fit, whatever the maxcounts say")
        // A remap that writes the lifetime can't be bounded: the maximum counts.
        var remapped = system(maximum: 3_000, rate: 10)
        var remap = ParticleInitializer(.remapInitialValue)
        remap.record.header.w = 1 << 9
        remapped.program.initializers.append(remap)
        XCTAssertEqual(ParticleBudget.capacity(of: remapped), 3_000)
    }

    /// Thinned systems hold fewer particles, as many as the scaled maximum allows.
    func testTheSimulationHoldsTheScaledMaximum() throws {
        var systems = [system(maximum: 400, rate: 2_000)]
        XCTAssertEqual(ParticleBudget.capacity(of: systems[0]), 400)
        ParticleBudget.apply(100, to: &systems)
        let runtime = ParticleSystemRuntime(texture: texture, configuration: systems[0], seed: 3)
        let gpu = try ParticleGPUStepper()
        for _ in 0..<60 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero))
        }
        XCTAssertEqual(gpu.particles(runtime).count, 100)
    }

    /// The loader counts every system of the scene, children, instances and the `count` override
    /// included, and thins them all when they exceed the budget; under it they stay as authored.
    func testTheLoaderAppliesTheBudgetToTheWholeScene() throws {
        _ = try Fixtures.assets()
        let directory = Fixtures.url("Scenes/particle-budget")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/particle-budget/project.json"))
        addTeardownBlock { Fixtures.removeStoredSettings(for: directory) }
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        var settings = SceneRenderSettings()
        settings.particleBudget = .unlimited
        model.setRenderSettings(settings)
        let authored = try XCTUnwrap(model.metalContent()).particleSystems
        XCTAssertEqual(authored.count, 3, "rain, its splashes, dust")
        XCTAssertEqual(authored.map(ParticleBudget.capacity(of:)), [10_000, 2_000, 4_000],
                       "rain 5000 × count 2; 50 splash instances of 20 × 2; dust 4000")
        XCTAssertEqual(authored.map(\.budgetScale), [1, 1, 1])
        settings.particleBudget = .medium
        model.setRenderSettings(settings)
        XCTAssertEqual(try XCTUnwrap(model.metalContent()).particleSystems.map(\.budgetScale), [1, 1, 1], "16 000 fit 25 000")
        settings.particleBudget = .low
        model.setRenderSettings(settings)
        let thinned = try XCTUnwrap(model.metalContent()).particleSystems
        XCTAssertEqual(thinned.map(\.budgetScale), Array(repeating: Float(10_000) / 16_000, count: 3))
        XCTAssertEqual(thinned.map(\.maximumParticleCount), authored.map(\.maximumParticleCount), "authored values kept")
    }
}
