import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Collision operators and audio response: decoding with WE's defaults, how a hit resolves, and
/// how they run in a simulated system.
final class ParticleCollisionAudioTests: XCTestCase {
    private func element(_ json: String) throws -> WEParticleOperator {
        try JSONDecoder().decode(WEParticleOperator.self, from: Data(json.utf8))
    }

    private let space = SceneParticleEmitterSpace(world: SceneAffineTransform(linear: matrix_identity_float2x2,
                                                                              translation: SIMD2(500, 500)))

    // MARK: - Collisions

    func testCollisionDefaultsAndBehaviours() throws {
        let plane = try XCTUnwrap(ParticleCollision(try element(#"{"name":"collisionplane"}"#), sceneSize: SIMD2(1920, 1080)))
        XCTAssertEqual(plane.shape, .plane(normal: SIMD3(0, 1, 0), distance: -150))
        XCTAssertEqual(plane.behavior, .bounce)
        XCTAssertEqual(plane.bounceFactor, 0.5)
        let sphere = try XCTUnwrap(ParticleCollision(try element(
            #"{"name":"collisionsphere","collisionbehavior":"slide","flags":3,"controlpoint":2}"#), sceneSize: .zero))
        XCTAssertEqual(sphere.shape, .sphere(origin: SIMD3(0, -200, 0), radius: 50))
        XCTAssertEqual(sphere.behavior, .slide)
        XCTAssertEqual(sphere.controlPoint, 2)
        XCTAssertTrue(sphere.stopsRotation)
        XCTAssertNil(ParticleCollision(try element(#"{"name":"collisionbox"}"#), sceneSize: .zero), "a no-op in WE")
        XCTAssertEqual(ParticleCollision.Behavior("stop"), .stop)
        XCTAssertEqual(ParticleCollision.Behavior("delete"), .delete)
        XCTAssertEqual(ParticleCollision.Behavior("bounce"), .bounce)
    }

    /// `bounds` is four planes fixed in the scene: an instance's position doesn't carry them.
    func testBoundsAreFourPlanesFixedInTheScene() throws {
        let bounds = ParticleCollision(shape: .bounds(size: SIMD2(1000, 800)), behavior: .slide)
        let planes = bounds.placed(in: space) { _ in .zero }
        XCTAssertEqual(planes.count, 4)
        XCTAssertEqual(planes[0].moved(by: SIMD2(100, 100)), planes[0], "bounds stay with the scene")
    }

    func testAControlPointAnchorsTheShape() throws {
        let sphere = ParticleCollision(shape: .sphere(origin: SIMD3(0, -200, 0), radius: 250), controlPoint: 1)
        let placed = try XCTUnwrap(sphere.placed(in: space) { $0 == 1 ? SIMD2(10, 20) : .zero }.first)
        XCTAssertEqual(placed.shape, SIMD4(10, 20, 250, 0))
    }

    // MARK: - Audio

    func testAudioResponseTakesTheBandsMaximum() throws {
        var spectrum = AudioSpectrumSnapshot.silent
        spectrum.left16[2] = 0.95
        spectrum.left16[3] = 0.5
        spectrum.right16[2] = 0.85
        let left = try XCTUnwrap(ParticleAudioResponse(mode: 1, exponent: nil, bounds: nil, frequencyStart: 1, frequencyEnd: 3))
        let t: Float = (0.95 - 0.8) / 0.2
        XCTAssertEqual(left.response(spectrum), pow(t * t * (3 - 2 * t), 2), accuracy: 1e-5)
        let both = try XCTUnwrap(ParticleAudioResponse(mode: 3, exponent: 1, bounds: SIMD2(0, 1), frequencyStart: 0, frequencyEnd: 15))
        let x: Float = 0.9
        XCTAssertEqual(both.response(spectrum), x * x * (3 - 2 * x), accuracy: 1e-5)
        XCTAssertNil(ParticleAudioResponse(mode: 0, exponent: nil, bounds: nil, frequencyStart: nil, frequencyEnd: nil))
        XCTAssertEqual(left.response(.silent), 0)
    }

    func testSilenceStopsAnAudioEmitterWithoutClearingIt() throws {
        let gpu = try ParticleGPUStepper()
        var configuration = ParticleTestSystem().configuration
        configuration.rateAudio = ParticleAudioResponse(mode: 3, exponent: 1, bounds: SIMD2(0, 1), frequencyStart: 0, frequencyEnd: 15)
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration)
        var loud = AudioSpectrumSnapshot.silent
        loud.left16 = [Float](repeating: 1, count: 16)
        loud.right16 = loud.left16
        for _ in 0..<10 {
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, audio: loud))
        }
        let count = gpu.particles(runtime).count
        XCTAssertGreaterThan(count, 50)
        let quiet = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, audio: .silent)
        XCTAssertEqual(quiet.emissionRate, 0)
        XCTAssertFalse(quiet.clears)
        gpu.step(runtime, inputs: quiet)
        XCTAssertEqual(gpu.particles(runtime).count, count)
    }

    // MARK: - Simulation

    /// Audio-driven turbulence, vortex and turbulent velocity under every collision shape: the
    /// particles stay inside the stopping bounds.
    func testCollisionsAndAudioRunTogether() throws {
        let gpu = try ParticleGPUStepper()
        gpu.sceneSize = SIMD2(1280, 720)
        var system = ParticleTestSystem()
        system.gravity = SIMD2(0, -600)
        system.lifetime = 2...3
        let response = ParticleAudioResponse(mode: 3, exponent: 1, bounds: SIMD2(0, 1), frequencyStart: 0, frequencyEnd: 3)
        var turbulence = ParticleOperator(.turbulence, a: SIMD4(1, 1, 0, 0), b: SIMD4(0.01, 200, 400, 0.5))
        turbulence.audio = response
        var vortex = ParticleOperator(.vortex, b: SIMD4(0, 0, 1, 0), c: SIMD4(0, 300, 200, 50))
        vortex.audio = response
        var velocity = ParticleInitializer(.turbulentVelocityRandom, a: SIMD4(100, 200, 0, 0.1), b: SIMD4(1, 1, 0, 0),
                                           c: SIMD4(0, 1, 0, 0), d: SIMD4(0, 0, 1, 0))
        velocity.audio = response
        system.initializers = [velocity]
        func collision(_ shape: ParticleCollision) -> ParticleOperator {
            var op = ParticleOperator(.collision)
            op.collision = shape
            return op
        }
        system.operators = [turbulence, vortex,
            collision(ParticleCollision(shape: .plane(normal: SIMD3(0.1, 1, 0), distance: -150), bounceFactor: 0.7)),
            collision(ParticleCollision(shape: .sphere(origin: SIMD3(80, -60, 0), radius: 40), behavior: .slide, stopsRotation: true)),
            collision(ParticleCollision(shape: .quad(origin: SIMD3(-80, -60, 0), normal: SIMD3(0, 1, 0), forward: SIMD3(0, 0, 1),
                                                     size: SIMD2(100, 100)), behavior: .delete)),
            collision(ParticleCollision(shape: .bounds(size: SIMD2(700, 1000)), behavior: .stop)),
        ]
        var configuration = system.configuration
        configuration.rateAudio = response
        let runtime = ParticleSystemRuntime(texture: try gpu.texture(), configuration: configuration, seed: 11)
        for frame in 0..<150 {
            var audio = AudioSpectrumSnapshot.silent
            let level = 0.5 + 0.5 * sin(Float(frame) * 0.1)
            audio.left16 = [Float](repeating: level, count: 16)
            audio.right16 = audio.left16
            let emitter = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(500, 500), scale: SIMD2(1, 1), angle: Float(frame) * 0.005))
            gpu.step(runtime, inputs: ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero,
                                                                  emitter: emitter, audio: audio))
        }
        let particles = gpu.particles(runtime)
        XCTAssertGreaterThan(particles.count, 100)
        for particle in particles {
            XCTAssertGreaterThanOrEqual(particle.position.x, -1e-3)
            XCTAssertLessThanOrEqual(particle.position.x, 700 + 1e-3)
        }
    }
}
