import XCTest
import AppKit
import Metal
import simd
@testable import OpenWallpaperEngine

/// `collisionmodel` (docs/models-plan.md §2.12, §4.3 M10): WE's capsule fit and placement, the
/// four responses against a capsule, a simulated system colliding, and the operator's link to its model.
final class ParticleCollisionModelTests: XCTestCase {
    // MARK: - Capsule fitting (0x1401d5880)

    func testTheFitTakesTheLargestExtentAsItsAxisAndTheSecondAsItsRadius() {
        func check(_ extent: SIMD3<Float>, axis: SIMD3<Float>, halfLength: Float, radius: SIMD3<Float>,
                   file: StaticString = #filePath, line: UInt = #line) {
            let fit = ParticleCapsule.fit(extent)
            XCTAssertEqual(fit.axis, axis, "axis of \(extent)", file: file, line: line)
            XCTAssertEqual(fit.halfLength, halfLength, accuracy: 1e-6, "half length of \(extent)", file: file, line: line)
            XCTAssertEqual(fit.radius, radius, "radius of \(extent)", file: file, line: line)
        }
        check(SIMD3(3, 1, 2), axis: SIMD3(1, 0, 0), halfLength: 1, radius: SIMD3(0, 0, 2))
        check(SIMD3(1, 3, 2), axis: SIMD3(0, 1, 0), halfLength: 1, radius: SIMD3(0, 0, 2))
        check(SIMD3(1, 2, 3), axis: SIMD3(0, 0, 1), halfLength: 1, radius: SIMD3(0, 2, 0))
        check(SIMD3(2, 1, 5), axis: SIMD3(0, 0, 1), halfLength: 3, radius: SIMD3(2, 0, 0))
        // Ties: x before y, x or y before z, the displaced one before the smaller of x and y only
        // when strictly larger.
        check(SIMD3(2, 2, 1), axis: SIMD3(1, 0, 0), halfLength: 0, radius: SIMD3(0, 2, 0))
        check(SIMD3(1, 1, 1), axis: SIMD3(1, 0, 0), halfLength: 0, radius: SIMD3(0, 1, 0))
        check(SIMD3(1, 2, 2), axis: SIMD3(0, 1, 0), halfLength: 0, radius: SIMD3(0, 0, 2))
    }

    func testABoneCapsuleIsItsBoxThroughTheModelTheBoneAndItsFrame() throws {
        // Half extents 3 × 1 × 0.5 in the bone's frame, moved 1 up the bone; the bone turned a
        // quarter about z and 10 along x; the model scaled 2 and moved 5 along z.
        var frame = matrix_identity_float4x4
        frame.columns.3 = SIMD4(0, 1, 0, 1)
        let bone = MDLSkeleton.BoneVector(vector: SIMD3(3, 1, 0.5), matrix: frame)
        var pose = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        pose.columns.3 = SIMD4(10, 0, 0, 1)
        var world = simd_float4x4(diagonal: SIMD4(2, 2, 2, 1))
        world.columns.3 = SIMD4(0, 0, 5, 1)
        let capsules = ParticleCapsule.capsules(boneVectors: [bone], boneWorlds: [pose], bounds: .unbounded, world: world)
        let capsule = try XCTUnwrap(capsules.first)
        XCTAssertEqual(capsules.count, 1, "one per bone; the box is only for models without the block")
        // The segment runs along the bone's x (turned to world y) through (10 − 1, 0) · 2: from
        // y = −2·2 to +2·2 (half length 3 − 1 = 2, scaled), at z 5.
        XCTAssertLessThan(simd_distance(capsule.start, SIMD3(18, -4, 5)), 1e-4)
        XCTAssertLessThan(simd_distance(capsule.direction, SIMD3(0, 1, 0)), 1e-5)
        XCTAssertEqual(capsule.length, 8, accuracy: 1e-4)
        XCTAssertEqual(capsule.radius, 2, accuracy: 1e-5, "the radius vector (0, 1, 0) scaled by 2")
    }

    func testTinyBoneBoxesAndBonesPastThePoseAreHandledAsWEDoes() throws {
        // |extent|² below 0.01: the degenerate capsule, a point with no radius.
        let tiny = MDLSkeleton.BoneVector(vector: SIMD3(0.05, 0.05, 0.05), matrix: matrix_identity_float4x4)
        let big = MDLSkeleton.BoneVector(vector: SIMD3(1, 0.5, 0.5), matrix: matrix_identity_float4x4)
        let capsules = ParticleCapsule.capsules(boneVectors: [tiny, big], boneWorlds: [matrix_identity_float4x4],
                                                bounds: .unbounded, world: matrix_identity_float4x4)
        XCTAssertEqual(capsules.count, 2)
        XCTAssertEqual(capsules[0], ParticleCapsule(start: .zero, direction: SIMD3(0, 1, 0), length: 0, radius: 0))
        // The second bone has no pose: the identity.
        XCTAssertLessThan(simd_distance(capsules[1].start, SIMD3(-0.5, 0, 0)), 1e-6)
        XCTAssertEqual(capsules[1].length, 1, accuracy: 1e-6)
        XCTAssertEqual(capsules[1].radius, 0.5, accuracy: 1e-6)
    }

    func testAModelWithoutBoneBoxesCollidesWithOneCapsuleFromItsBox() throws {
        let bounds = MDLBounds(min: SIMD3(-1, -2, 1), max: SIMD3(1, 2, 7))
        var world = matrix_identity_float4x4
        world.columns.3 = SIMD4(100, 0, 0, 1)
        let capsules = ParticleCapsule.capsules(boneVectors: nil, boneWorlds: [], bounds: bounds, world: world)
        let capsule = try XCTUnwrap(capsules.first)
        XCTAssertEqual(capsules.count, 1)
        // Half extents (1, 2, 3) about (0, 0, 4): along z, half length 3 − 2, radius 2.
        XCTAssertLessThan(simd_distance(capsule.start, SIMD3(100, 0, 3)), 1e-5)
        XCTAssertEqual(capsule.direction, SIMD3(0, 0, 1))
        XCTAssertEqual(capsule.length, 2, accuracy: 1e-6)
        XCTAssertEqual(capsule.radius, 2, accuracy: 1e-6)
        XCTAssertTrue(ParticleCapsule.capsules(boneVectors: [], boneWorlds: [], bounds: MDLBounds(min: .zero, max: .zero),
                                               world: world).isEmpty, "an empty box gives none")
    }

    // MARK: - Simulation

    private var gpu: ParticleGPUStepper!

    override func setUpWithError() throws {
        gpu = try ParticleGPUStepper()
        gpu.sceneSize = SIMD2(1280, 720)
    }

    func testASystemCollidesWithItsModelsCapsules() throws {
        let texture = try gpu.texture()
        // Particles fall from (500, 500) onto a capsule across their path, tilted in depth so the
        // hits push them along z too, next to a second one they fall past.
        let capsules = [ParticleCapsule(start: SIMD3(380, 430, -20), direction: simd_normalize(SIMD3(240, 0, 40)),
                                        length: simd_length(SIMD3<Float>(240, 0, 40)), radius: 25),
                        ParticleCapsule(start: SIMD3(700, 300, 0), direction: SIMD3(0, 1, 0), length: 50, radius: 10)]
        func mean(_ values: [ParticleGPUState]) -> SIMD4<Float> {
            let total: SIMD4<Float> = values.reduce(SIMD4<Float>.zero) { (sum: SIMD4<Float>, p: ParticleGPUState) -> SIMD4<Float> in
                sum + SIMD4<Float>(p.position.x, p.position.y, p.z, p.zVelocity)
            }
            return total / Float(max(values.count, 1))
        }
        var plain = ParticleTestSystem()
        plain.gravity = SIMD2(0, -400)
        // The same system without the capsules.
        let free = ParticleSystemRuntime(texture: texture, configuration: plain.configuration, seed: 7)
        for _ in 0..<120 {
            gpu.step(free, inputs: ParticleFrameInputs.advance(free, deltaTime: 1 / 60, cursor: .zero))
        }
        let freeParticles = gpu.particles(free)
        let unhindered = mean(freeParticles)
        for behavior in [ParticleCollision.Behavior.bounce, .slide, .stop, .delete] {
            var system = plain
            var model = ParticleOperator(.collision)
            model.collision = ParticleCollision(shape: .model(index: 1), behavior: behavior, bounceFactor: 0.7)
            system.operators = [model]
            var configuration = system.configuration
            configuration.collisionModels = [1: "model"]
            let runtime = ParticleSystemRuntime(texture: texture, configuration: configuration, seed: 7)
            let provider = { (id: String) -> [ParticleCapsule] in id == "model" ? capsules : [] }
            for _ in 0..<120 {
                let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero, modelCapsules: provider)
                XCTAssertEqual(inputs.collisions.count, 2)
                XCTAssertEqual(inputs.operators.last?.header.z, 0 | 2 << 16, "the operator's capsules")
                gpu.step(runtime, inputs: inputs)
            }
            let particles = gpu.particles(runtime)
            XCTAssertGreaterThan(particles.count, 50, "\(behavior)")
            // The capsules changed the particles, against the same system without them.
            if behavior == .delete {
                XCTAssertLessThan(particles.count, freeParticles.count - 20, "delete: particles hitting the capsule die")
            } else {
                let held = mean(particles)
                XCTAssertGreaterThan(held.y - unhindered.y, 5, "\(behavior): held up by the capsule")
                let depth: Float = abs(held.z) + abs(held.w)
                XCTAssertGreaterThan(depth, 0.01, "\(behavior): the tilted capsule pushed them in depth")
            }
        }
    }

    // MARK: - The operator and its link

    func testTheOperatorIsLinkedByItsSlotAfterTheLayerImageEmitters() throws {
        let json = #"""
        {"emitter": [{"name": "layerimage"}, {"name": "sphererandom"}],
         "operator": [{"name": "collisionmodel", "collisionbehavior": "slide", "bouncefactor": 0.2},
                      {"name": "collisionplane"},
                      {"name": "collisionmodel"}]}
        """#
        let particles = try JSONDecoder().decode(WEParticleSystem.self, from: Data(json.utf8))
        let object = try JSONDecoder().decode(WESceneObject.self, from: Data(#"""
        {"id": 1, "name": "p", "particle": "p.json",
         "dependencies": [{"id": 7, "type": "emitterimage", "index": 0}, {"id": 42, "type": "collisionmodel", "index": 1},
                          {"id": 43, "type": "collisionmodel", "index": 2}, 12]}
        """#.utf8))
        let configuration = ParticleSystemBuilder.build(
            "p.json", particleSystem: particles, object: object, world: .identity, overrides: SceneParticleOverrides(),
            sceneSize: SIMD2(1000, 1000), source: .image(NSImage()), spriteSheet: nil, material: WEMaterial(),
            materialPlan: nil, pixelUnits: false)
        let collisions = configuration.program.operators.compactMap(\.collision)
        XCTAssertEqual(collisions.map(\.modelIndex), [1, nil, 2], "the slots after the one layerimage emitter")
        XCTAssertEqual(collisions[0].behavior, .slide)
        XCTAssertEqual(collisions[0].bounceFactor, 0.2)
        XCTAssertEqual(collisions[2].behavior, .bounce)
        XCTAssertEqual(collisions[2].bounceFactor, 0.5)
        XCTAssertEqual(ParticleCollision.linkedModels(object.dependencies ?? []), [1: "42", 2: "43"])
    }

    func testAnUnlinkedOperatorCollidesWithNothingAndLeavesTheOthersInPlace() throws {
        let texture = try gpu.texture()
        var system = ParticleTestSystem()
        var model = ParticleOperator(.collision)
        model.collision = ParticleCollision(shape: .model(index: 0))
        var plane = ParticleOperator(.collision)
        plane.collision = ParticleCollision(shape: .plane(normal: SIMD3(0, 1, 0), distance: -60))
        system.operators = [model, plane]
        let runtime = ParticleSystemRuntime(texture: texture, configuration: system.configuration)
        let inputs = ParticleFrameInputs.advance(runtime, deltaTime: 1 / 60, cursor: .zero,
                                                 modelCapsules: { _ in XCTFail("no link, no lookup"); return [] })
        XCTAssertEqual(inputs.collisions.count, 1)
        XCTAssertEqual(inputs.collisions.first?.kind, .plane)
        let records = inputs.operators.filter { $0.header.x == ParticleOperatorKind.collision.rawValue }
        XCTAssertEqual(records.map(\.header.z), [0, 0 | 1 << 16], "the plane keeps its own range")
    }
}
