import XCTest
import Metal
import simd
@testable import OpenWallpaperEngine

/// Particle systems follow their emitter's live transform: particles in the emitter's space move,
/// turn and scale with it; `worldspace` ones stay where they spawned. And a live parent (moved by
/// its timeline) moves the emitter, and particle systems in turn parent other objects.
final class ParticleEmitterMotionTests: XCTestCase {
    private var gpu: ParticleGPUStepper!
    private var texture: MTLTexture!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
        texture = try gpu.texture()
    }

    /// Still particles, so any change of position comes from the emitter.
    private func stillSystem(worldSpace: Bool) -> ParticleSystemRuntime {
        var system = ParticleTestSystem()
        system.origin = SIMD2(100, 100)
        system.minimumVelocity = .zero
        system.maximumVelocity = .zero
        system.lifetime = 50...50
        system.angularVelocity = 0...0
        system.worldSpace = worldSpace
        return ParticleSystemRuntime(texture: texture, configuration: system.configuration, seed: 3)
    }

    private func step(_ system: ParticleSystemRuntime, emitter: SceneAffineTransform, frames: Int = 1) {
        for _ in 0..<frames {
            gpu.step(system, inputs: ParticleFrameInputs.advance(system, deltaTime: 1 / 60, cursor: .zero, emitter: emitter))
        }
    }

    /// `system`'s live particles by serial.
    private func particles(_ system: ParticleSystemRuntime) -> [UInt32: ParticleGPUState] {
        Dictionary(gpu.particles(system).map { ($0.serial, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func translation(_ point: SIMD2<Float>) -> SceneAffineTransform {
        SceneAffineTransform(linear: matrix_identity_float2x2, translation: point)
    }

    func testLocalParticlesMoveWithTheirEmitter() throws {
        let system = stillSystem(worldSpace: false)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        let before = particles(system)
        XCTAssertGreaterThan(before.count, 50)
        step(system, emitter: translation(SIMD2(300, 50)))
        let after = particles(system)
        for (serial, old) in before {
            let new = try XCTUnwrap(after[serial])
            XCTAssertLessThan(simd_distance(new.position - old.position, SIMD2<Float>(200, -50)), 1e-3)
        }
    }

    func testWorldSpaceParticlesStayWhereTheySpawned() throws {
        let system = stillSystem(worldSpace: true)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        let before = particles(system)
        step(system, emitter: translation(SIMD2(300, 50)))
        let after = particles(system)
        for (serial, old) in before {
            XCTAssertLessThan(simd_distance(try XCTUnwrap(after[serial]).position, old.position), 1e-4)
        }
        XCTAssertGreaterThan(after.count, before.count)
        let newest = try XCTUnwrap(after.keys.max())
        let spawned = try XCTUnwrap(after[newest])
        XCTAssertLessThan(simd_distance(spawned.position, SIMD2<Float>(300, 50)), 60, "new particles spawn at the emitter")
    }

    func testTurningAndScalingTheEmitterTurnsAndScalesItsParticles() throws {
        let system = stillSystem(worldSpace: false)
        step(system, emitter: translation(SIMD2(100, 100)), frames: 20)
        XCTAssertEqual(system.drawLinear, matrix_identity_float2x2)
        let before = particles(system)
        let turned = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(2, 2), angle: .pi / 2))
        step(system, emitter: turned)
        let after = particles(system)
        for (serial, old) in before {
            let new = try XCTUnwrap(after[serial])
            let expected: SIMD2<Float> = turned.apply(old.position - SIMD2<Float>(100, 100))
            XCTAssertLessThan(simd_distance(new.position, expected), 1e-3)
            XCTAssertEqual(new.size, old.size, accuracy: 1e-5, "sizes stay the emitter's own")
            XCTAssertEqual(new.rotation, old.rotation, accuracy: 1e-5)
        }
        XCTAssertEqual(system.drawLinear, turned.linear, "the emitter's transform draws them, as WE's model matrix")
    }

    /// WE expands a sprite in its system's space and draws it through the system's model matrix,
    /// so a non-uniform scale squashes it (and a turn turns it).
    func testANonUniformScaleSquashesSprites() throws {
        let system = stillSystem(worldSpace: false)
        let squashed = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(3, 0.5), angle: 0))
        step(system, emitter: squashed)
        // The quad's axes the GPU's built-in draw takes (`spriteAxes` in `ParticleShared.h`): a sprite
        // of `size` turned by `rotation` in the shader's y-down corner space, through `spriteLinear`.
        func spriteAxes(size: Float, rotation: Float) -> (x: SIMD2<Float>, y: SIMD2<Float>) {
            let c = cos(rotation), s = sin(rotation)
            let x: SIMD2<Float> = system.spriteLinear * (SIMD2<Float>(c, -s) * size)
            let y: SIMD2<Float> = system.spriteLinear * (SIMD2<Float>(-s, -c) * size)
            return (x, -y)
        }
        let axes = spriteAxes(size: 10, rotation: 0)
        XCTAssertEqual(axes.x.x, 30, accuracy: 1e-4)
        XCTAssertEqual(axes.x.y, 0, accuracy: 1e-4)
        XCTAssertEqual(axes.y.x, 0, accuracy: 1e-4)
        XCTAssertEqual(axes.y.y, 5, accuracy: 1e-4)
        // A quarter-turned sprite swaps its axes before the scale: now tall and narrow.
        let turned = spriteAxes(size: 10, rotation: .pi / 2)
        XCTAssertEqual(simd_length(turned.x), 5, accuracy: 1e-4)
        XCTAssertEqual(simd_length(turned.y), 30, accuracy: 1e-4)
        XCTAssertEqual(system.drawSizeScale, 1, "sprites take the transform whole")
    }

    func testWorldSpaceParticlesTakeTheEmitterScaleWhenTheySpawn() throws {
        let system = stillSystem(worldSpace: true)
        let scaled = SceneAffineTransform(SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(2, 2), angle: 0))
        step(system, emitter: scaled, frames: 5)
        XCTAssertEqual(system.drawLinear, matrix_identity_float2x2, "they left the emitter's space")
        let local = stillSystem(worldSpace: false)
        step(local, emitter: scaled, frames: 5)
        let world = particles(system), own = particles(local)
        XCTAssertGreaterThan(world.count, 0)
        for (serial, particle) in world {
            let same = try XCTUnwrap(own[serial])
            XCTAssertEqual(particle.size, same.size * 2, accuracy: 1e-4)
        }
    }

    // MARK: - Live parents

    private func content(_ fixture: String) throws -> SceneMetalContent {
        let directory = Fixtures.url("Scenes/\(fixture)")
        let project = try JSONDecoder().decode(WEProject.self, from: Fixtures.data("Scenes/\(fixture)/project.json"))
        addTeardownBlock {
            Fixtures.removeStoredSettings(for: directory)
        }
        return try XCTUnwrap(SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory)).metalContent())
    }

    /// Every object's own transform after `time` seconds of the content's timelines, the way the
    /// renderer evaluates it for objects that aren't drawn layers.
    private func locals(_ content: SceneMetalContent, at time: Float) throws -> (String) -> SceneLocalTransform? {
        let source = try XCTUnwrap(content.timelines)
        let set = SceneAnimationSet(document: source.document, wallpaperID: source.wallpaperID)
        set.advance(by: time)
        return { id in
            content.motions[id]?.local(animation: Int(id).map { SceneObjectAnimation(set, object: $0) })
        }
    }

    private func world(_ id: String, in content: SceneMetalContent, at time: Float) throws -> SceneAffineTransform {
        content.transforms.world(of: id, live: try locals(content, at: time))
    }

    func testEmittersFollowTheirAnimatedParent() throws {
        _ = try Fixtures.assets()
        let content = try content("particle-animated-parent")
        let systems = content.particleSystems
        XCTAssertEqual(systems.map(\.objectID), ["2", "3"])
        XCTAssertEqual(systems.map(\.worldSpace), [false, true])
        XCTAssertNotNil(content.motions["1"], "a group without a layer still moves its children")
        let start = try world("2", in: content, at: 0)
        XCTAssertLessThan(simd_distance(start.translation, SIMD2(500, 540)), 1e-3)
        XCTAssertEqual(start, systems[0].authoredWorld)
        // Halfway: the pivot is at (900, 540), turned a counter-clockwise eighth.
        let halfway = try world("2", in: content, at: 1)
        let expected = SIMD2<Float>(900, 540) + SIMD2(100, 100) / sqrt(2)
        // WE's sampler finds the curve's x by bisection to 0.01 frames, linear handles included.
        XCTAssertLessThan(simd_distance(halfway.translation, expected), 0.1)
    }

    func testParticleSystemsParentOtherObjectsLive() throws {
        _ = try Fixtures.assets()
        let content = try content("particle-animated-parent")
        let marker = try XCTUnwrap(content.layers.first { $0.id == "4" })
        let emitter = try world("2", in: content, at: 1)
        let markerWorld = content.transforms.parentWorld(of: marker.id, live: try locals(content, at: 1))
            * SceneAffineTransform(SceneLocalTransform(origin: marker.position, scale: marker.scale, angle: marker.rotation))
        XCTAssertLessThan(simd_distance(markerWorld.translation, emitter.apply(SIMD2(0, 50))), 1e-2)
    }
}
