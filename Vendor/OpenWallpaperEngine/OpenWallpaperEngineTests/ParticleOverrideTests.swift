import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

private struct Properties: SceneValueContext {
    var values: [String: String] = [:]
    func userProperty(_ name: String) -> String? { values[name] }
    func evaluateScript(_ source: String, properties: SceneScriptProperties, current: ShaderValue) -> ShaderValue? { nil }
}

/// A particle object's `instanceoverride` scales the authored values every frame, so a user
/// property it's bound to takes effect without rebuilding the scene.
final class ParticleOverrideTests: XCTestCase {
    private var gpu: ParticleGPUStepper!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
        texture = try gpu.texture()
    }

    private func boundOverride() throws -> WEInstanceOverride {
        try JSONDecoder().decode(WEInstanceOverride.self, from: Data(#"""
        {"count": {"user": "amount", "value": 0.5}, "rate": {"user": "amount", "value": 0.5},
         "size": {"user": "flakesize", "value": 2}, "alpha": 0.5, "lifetime": 3, "speed": 2,
         "colorn": {"user": "tint", "value": "1 0.5 0.25"}, "brightness": 2}
        """#.utf8))
    }

    func testBoundOverridesResolveEveryFrame() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.maximum = 1000
        var configuration = system.configuration
        configuration.liveOverrides = try boundOverride()
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
        let defaults = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        // `count` scales the emitter's rate (0x1401c6e6c binds it to the count); `rate` doesn't.
        XCTAssertEqual(defaults.emissionRate, 50, accuracy: 1e-4)
        XCTAssertEqual(defaults.maximum, 500)
        XCTAssertEqual(defaults.spawnScale, SIMD4(2, 0.5, 3, 2))
        XCTAssertEqual(defaults.colorScale, SIMD3(2, 1, 0.5))
        // A change moves the system's binding revision, as `SceneBindingUpdate` does in the renderer.
        runtime.bindingRevision += 1
        let changed = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties(values: [
            "amount": "0.25", "flakesize": "4", "tint": "0 1 0"]))
        XCTAssertEqual(changed.emissionRate, 25, accuracy: 1e-4)
        XCTAssertEqual(changed.maximum, 250)
        XCTAssertEqual(changed.spawnScale.x, 4)
        XCTAssertEqual(changed.colorScale, SIMD3(0, 2, 0))
    }

    func testControlPointOverridesPlaceControlPoints() throws {
        let json = "{\"controlpoint1\": \"-3382.5 384 0\", \"controlpoint2\": {\"user\": \"spot\", \"value\": \"10 20 0\"}}"
        let override = try JSONDecoder().decode(WEInstanceOverride.self, from: Data(json.utf8))
        let defaults = SceneParticleOverrides(override, in: Properties())
        XCTAssertEqual(defaults.controlPoints, [1: SIMD3(-3382.5, 384, 0), 2: SIMD3(10, 20, 0)])
        let bound = SceneParticleOverrides(override, in: Properties(values: ["spot": "5 6 0"]))
        XCTAssertEqual(bound.controlPoints[2], SIMD3(5, 6, 0))
    }

    /// WE 2.8.0.42 (flagtests `pf_childflags_0/2`): a static child with link flags 0 and one with 2
    /// both come out in the layer's `colorn` (mean 133,12,14 and 134,12,14). Flag 2 restarts the
    /// child with its parent's periods; it doesn't keep the child's colours.
    func testAChildWithLinkFlag2TakesTheTint() throws {
        let child = try JSONDecoder().decode(WEParticleChild.self, from: Data(#"{"name": "c.json", "flags": 2}"#.utf8))
        let link = ParticleFamilyBuilder.link(child, kind: .static, parentIndex: 0, parent: nil)
        XCTAssertTrue(link.restartsWithParentPeriod)
        var configuration = ParticleTestSystem().configuration
        configuration.overrides = SceneParticleOverrides(try boundOverride(), in: Properties())
        configuration.link = link
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        XCTAssertEqual(inputs.colorScale, configuration.overrides.tint * configuration.overrides.brightness)
        XCTAssertNotEqual(inputs.colorScale, SIMD3(repeating: 1))
    }

    /// WE's particle parser binds the `rate` override to the turbulence operators' `timescale`
    /// only (0x1401c8bc5 `turbulentvelocityrandom`, 0x1401cd7ba `turbulence`); the emitters' rate
    /// is bound to `count` (0x1401c6e6c). WE's element previews with `rate` 2.33
    /// (maintaindistancetocontrolpoint, reducemovementnearcontrolpoint) emit at their authored rate.
    func testTheRateOverrideScalesTurbulenceNotEmission() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 100
        system.operators = [ParticleOperator(.turbulence, b: SIMD4(0.01, 500, 1000, 20))]
        system.initializers = [ParticleInitializer(.turbulentVelocityRandom, a: SIMD4(100, 250, 0, 0.1), b: SIMD4(1, 1, 0, 0))]
        var configuration = system.configuration
        configuration.overrides.rate = 2.5
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        XCTAssertEqual(inputs.emissionRate, 100)
        XCTAssertEqual(try XCTUnwrap(inputs.operators.last).b.w, 50)
        XCTAssertEqual(try XCTUnwrap(inputs.initializers.last).b.x, 2.5)
    }

    /// Besides the emitters' and velocity initializers' speeds, WE's parser binds the `speed`
    /// override to `movement` gravity (0x1401cb52f), `angularmovement` force (0x1401cb85e),
    /// `oscillateposition` frequency (0x1401cc416), `controlpointattract` scale (0x1401ccd7b),
    /// `turbulence` speed (0x1401cd872), `vortex`/`vortex_v2` speeds (0x1401cdddc, 0x1401ce39b),
    /// `inheritcontrolpointvelocity` (0x1401c870f) and `mapsequencearoundcontrolpoint` speeds
    /// (0x1401ca151); and the `size` override to `sizechange` (0x1401cbb48). The system's flags
    /// 0x10 and 0x80 switch those off.
    func testTheSpeedAndSizeOverridesScaleTheFieldsWEBinds() throws {
        let one = SIMD4<Float>(1, 2, 3, 4)
        var system = ParticleTestSystem()
        system.operators = [ParticleOperatorKind.movement, .angularMovement, .oscillatePosition, .controlPointAttract,
                            .turbulence, .vortex, .vortexV2, .sizeChange, .oscillateSize]
            .map { ParticleOperator($0, a: one, b: one, c: one, d: one) }
        system.initializers = [ParticleInitializerKind.inheritControlPointVelocity, .mapSequenceAroundControlPoint, .velocityRandom]
            .map { ParticleInitializer($0, a: one, b: one, c: one, d: one) }
        var configuration = system.configuration
        configuration.overrides.speed = 2
        configuration.overrides.size = 3
        func records(ignoring parts: SceneParticleOverrides.Parts) -> ParticleFrameInputs {
            var configuration = configuration
            configuration.ignoredOverrides = parts
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration)
            return ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties())
        }
        let inputs = records(ignoring: [])
        func op(_ kind: ParticleOperatorKind) throws -> ParticleProgramOp {
            try XCTUnwrap(inputs.operators.last { $0.header.x == kind.rawValue })
        }
        func initializer(_ kind: ParticleInitializerKind) throws -> ParticleProgramOp {
            try XCTUnwrap(inputs.initializers.last { $0.header.x == kind.rawValue })
        }
        XCTAssertEqual(try op(.movement).a, SIMD4<Float>(2, 4, 6, 4), "gravity, not drag")
        XCTAssertEqual(try op(.angularMovement).a, SIMD4<Float>(2, 4, 6, 4), "force, not drag")
        XCTAssertEqual(try op(.oscillatePosition).b, SIMD4<Float>(2, 4, 3, 4), "frequency, not phase")
        XCTAssertEqual(try op(.oscillatePosition).c, one, "nor scale")
        XCTAssertEqual(try op(.controlPointAttract).b, SIMD4<Float>(2, 2, 3, 4), "scale, not the thresholds")
        XCTAssertEqual(try op(.turbulence).b, SIMD4<Float>(1, 4, 6, 4), "speed, not scale or timescale")
        XCTAssertEqual(try op(.vortex).c, SIMD4<Float>(1, 2, 6, 8), "speeds, not distances")
        XCTAssertEqual(try op(.vortexV2).b, SIMD4<Float>(1, 2, 6, 8))
        XCTAssertEqual(try op(.sizeChange).a, SIMD4<Float>(3, 6, 3, 4), "start and end values, not the times")
        XCTAssertEqual(try op(.oscillateSize).b, one, "oscillatesize isn't bound")
        XCTAssertEqual(try initializer(.inheritControlPointVelocity).a, SIMD4<Float>(2, 4, 3, 4))
        XCTAssertEqual(try initializer(.mapSequenceAroundControlPoint).b, SIMD4<Float>(2, 4, 6, 4))
        XCTAssertEqual(try initializer(.mapSequenceAroundControlPoint).c, SIMD4<Float>(2, 4, 6, 4))
        XCTAssertEqual(try initializer(.velocityRandom).a, one, "scaled at spawn (spawnScale.w) instead")
        XCTAssertEqual(inputs.spawnScale.w, 2)

        // The test system's own movement and initializers come first; the ones above are last.
        let ignored = records(ignoring: [.speed, .size])
        let operators = Array(ignored.operators.suffix(system.operators.count))
        let initializers = Array(ignored.initializers.suffix(system.initializers.count))
        XCTAssertEqual(operators.map(\.a), system.operators.map(\.record.a))
        XCTAssertEqual(operators.map(\.b), system.operators.map(\.record.b))
        XCTAssertEqual(operators.map(\.c), system.operators.map(\.record.c))
        XCTAssertEqual(initializers.map(\.a), system.initializers.map(\.record.a))
        XCTAssertEqual(initializers.map(\.b), system.initializers.map(\.record.b))
    }

    /// WE's particle parser binds every emitter's `speedmin` and `speedmax` to the `speed`
    /// override (0x1401c6354, 0x1401c6a86, 0x1401c6f9c; not with the system's flag 0x10), so the
    /// `collisionbounds` preview's `speed` 2.9 launches its particles 2.9 × as fast.
    func testTheSpeedOverrideScalesTheEmittersSpeed() throws {
        var system = ParticleTestSystem()
        system.emissionRate = 60
        system.emitterSpeed = SIMD2(100, 100)
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        func launchSpeeds(_ speed: Float) -> [Float] {
            var configuration = system.configuration
            configuration.overrides.speed = speed
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 2)
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties()))
            return gpu.particles(runtime).map { simd_length($0.velocity) }
        }
        let speeds = launchSpeeds(1)
        XCTAssertEqual(speeds.count, 1)
        XCTAssertEqual(try XCTUnwrap(speeds.first), 100, accuracy: 1e-3)
        let fast = try XCTUnwrap(launchSpeeds(2.9).first)
        XCTAssertEqual(fast, 290, accuracy: 1e-3)
    }

    /// The bound overrides shape what spawns: `count` halves the maximum, `size` doubles the sizes.
    func testOverriddenSpawns() throws {
        gpu.sceneSize = SIMD2(1280, 720)
        var system = ParticleTestSystem()
        system.emissionRate = 3000
        system.emitterSpeed = SIMD2(20, 80)
        var configuration = system.configuration
        configuration.overrides = SceneParticleOverrides(try boundOverride(), in: Properties())
        let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 5)
        for _ in 0..<60 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, values: Properties()))
        }
        let particles = gpu.particles(runtime)
        XCTAssertEqual(particles.count, 500, "the count override halves the maximum")
        let sizes = particles.map(\.size)
        // WE's base size is 0.5, which `sizerandom` multiplies (wallpaper64.exe 0x14023b340).
        XCTAssertGreaterThanOrEqual(sizes.min() ?? 0, 10, "authored 10…20 on the base 0.5, doubled")
    }
}
