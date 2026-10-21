import XCTest
import simd
@testable import OpenWallpaperEngine

/// Physics bones (docs/models-plan.md §2.14): the constraint JSON as WE's loader reads it
/// (0x140265c30), the simulation of the puppet update (0x14020136e…) against values worked out
/// by hand from its formulas, and the script calls (0x140210990, 0x140210e10).
final class SceneBonePhysicsTests: XCTestCase {
    private static let delta: Float = 1.0 / 60
    private static let degrees = 0.017453292

    // MARK: - The constraint

    /// A rigid bone of the Samurai (2321732083): `rax` null locks nothing, inertia is `1 − ri/100`.
    func testLibraryRigidConstraint() throws {
        let physics = try XCTUnwrap(MDLBonePhysics(properties: #"""
            {"a":"-0.8910065241883678 -0.45399049973954686 0","gd":"6.123233995736766e-17 -1 0","ge":false,"la":true,\#
            "lamax":"0 0 0.3141592653589793","lamin":"0 0 -0.3141592653589793","lt":false,"ltmax":100,"m":20,"r":true,\#
            "rax":null,"ray":null,"raz":null,"re":true,"rf":10,"ri":19.700001,"rs":200,"s":0,"se":false,"t":false,\#
            "tf":10,"ti":30,"tm":200.0,"tp":"-89.10065 -45.39905 0.00000","ts":200}
            """#))
        XCTAssertEqual(physics.flags, [.rigid, .rotation, .limitAngles])
        XCTAssertTrue(physics.isSimulated)
        let inertia: Float = 1 - 0.19700001
        XCTAssertEqual(physics.rotationInertia, inertia, accuracy: 1e-6)
        XCTAssertEqual(physics.translationInertia, 0.7, accuracy: 1e-6)
        XCTAssertEqual(physics.rotationFriction, 10)
        XCTAssertEqual(physics.translationFriction, 10, "a physics bone keeps tf as authored")
        XCTAssertEqual(physics.mass, 20)
        XCTAssertEqual(physics.maxTorque, 100)
        XCTAssertEqual(physics.tip.x, -89.10065, accuracy: 1e-4)
        XCTAssertEqual(physics.tip.y, -45.39905, accuracy: 1e-4)
        XCTAssertEqual(physics.maxAngles.z, 0.31415927, accuracy: 1e-6)
        XCTAssertEqual(physics.minAngles.z, -0.31415927, accuracy: 1e-6)
        XCTAssertEqual(physics.gravityDirection.y, -1)
    }

    /// Defaults (0x14026b860), the IK path, cleared flags, axis locks and the vector reader.
    func testConstraintKeysAndDefaults() throws {
        let bare = try XCTUnwrap(MDLBonePhysics(properties: #"{"se":true,"t":true}"#))
        XCTAssertEqual(bare.mass, 1000)
        XCTAssertEqual(bare.rotationInertia, 1)
        XCTAssertEqual(bare.tip, .zero)
        XCTAssertEqual(bare.maxDistance, 0)

        let ik = try XCTUnwrap(MDLBonePhysics(properties: #"{"ik":true,"r":true,"tf":50,"rs":9,"ikse":true}"#))
        XCTAssertEqual(ik.flags, [.ik, .rotation, .ikStretch])
        XCTAssertFalse(ik.isSimulated)
        XCTAssertEqual(ik.translationFriction, 0.25, accuracy: 1e-6, "an IK bone keeps (tf / 100)²")
        XCTAssertEqual(ik.rotationStiffness, 0, "the physics keys aren't read for an IK bone")

        XCTAssertNil(MDLBonePhysics(properties: #"{"r":true,"rs":5}"#), "neither simulated nor IK: the flags clear")
        XCTAssertNil(MDLBonePhysics(properties: ""))
        XCTAssertNil(MDLBonePhysics(properties: "not json"))
        XCTAssertEqual(MDLBonePhysics(properties: #"{"ikce":true}"#)?.flags, [.ikConstrained])

        let locked = try XCTUnwrap(MDLBonePhysics(properties: #"""
            {"se":true,"r":true,"rax":false,"ray":true,"raz":true,"tax":true,"tay":false,"taz":1,"m":"5","la":1}
            """#))
        XCTAssertEqual(locked.flags, [.spring, .rotation, .lockRotationX], "the axes count only when all three are bools")
        XCTAssertEqual(locked.mass, 1000, "a string isn't a number")

        XCTAssertEqual(MDLBonePhysics.vector("1 2 3"), SIMD3(1, 2, 3))
        XCTAssertEqual(MDLBonePhysics.vector("4.5"), SIMD3(4.5, 0, 0))
        XCTAssertEqual(MDLBonePhysics.vector("1   -2 "), SIMD3(1, -2, 0))
        XCTAssertTrue(MDLBonePhysics.vector("-nan(ind) 0 0").x.isNaN)
    }

    // MARK: - The simulation

    /// Three bones through `FixtureMDL`: a root, `tail` 100 right of it with `physics`, and
    /// `end` 100 right of the tail with `child`.
    private static func rig(_ physics: String, child: String = "") throws -> MDLSkeleton {
        let cube = FixtureMDL.cube(material: "materials/facecolor.json", bone: 0)
        let mdl = FixtureMDL(format: FixtureMDL.skinned, materialsPerMesh: 1,
                             meshes: [FixtureMDL.Mesh(materials: ["materials/facecolor.json"], vertices: cube.vertices,
                                                      indices: cube.indices)],
                             skeleton: [FixtureMDL.Bone(name: "root"),
                                        FixtureMDL.Bone(name: "tail", parent: 0, matrix: ScenePuppetTests.translation(SIMD3(100, 0, 0)),
                                                        properties: physics),
                                        FixtureMDL.Bone(name: "end", parent: 1, matrix: ScenePuppetTests.translation(SIMD3(100, 0, 0)),
                                                        properties: child)])
        return try XCTUnwrap(MDLReader.read(mdl.data).skeleton)
    }

    private static func animator(_ physics: String, child: String = "") throws -> ScenePuppetAnimator {
        ScenePuppetAnimator(skeleton: try rig(physics, child: child), clips: [], layers: [])
    }

    private static func advance(_ animator: ScenePuppetAnimator, world: simd_float4x4 = matrix_identity_float4x4) {
        animator.advance(delta: delta, values: EmptySceneValues(), objectWorld: world)
    }

    /// The z angle of the tail's rotation in model space.
    private static func angle(_ animator: ScenePuppetAnimator) -> Float {
        atan2(animator.worlds[1].columns.0.y, animator.worlds[1].columns.0.x)
    }

    /// The fixture's bytes carry the constraint; rigs without a simulated bone have no physics
    /// and pose exactly as before, however the object moves.
    func testRigsWithoutPhysicsBonesAreUnchanged() throws {
        let skeleton = try Self.rig(#"{"se":true,"t":true,"ts":300}"#)
        XCTAssertEqual(skeleton.bones[1].properties, #"{"se":true,"t":true,"ts":300}"#)
        XCTAssertNotNil(SceneBonePhysics(skeleton)?.constraints[1])
        XCTAssertNil(SceneBonePhysics(skeleton)?.constraints[0])

        for properties in ["", #"{"ik":true,"r":true}"#, #"{"r":true,"t":true,"ts":300}"#] {
            let animator = try Self.animator(properties)
            XCTAssertNil(animator.physics, properties)
            let bind = animator.skeleton.bindWorld
            for x in [0, 25, -40] as [Float] {
                Self.advance(animator, world: ScenePuppetTests.translation(SIMD3(x, 0, 0)))
                XCTAssertEqual(animator.worlds, bind, properties)
            }
        }
    }

    /// A spring's offset: the tail keeps 70 % of its parent's move (`ti` 30), the spring (`ts`
    /// 300) pulls it back, friction (`tf` 12) slows it. Nothing happens on the first frame (WE
    /// has no last-frame bones yet); the end, a child, follows the tail.
    func testSpringTranslationStepResponse() throws {
        let animator = try Self.animator(#"{"se":true,"t":true,"r":false,"ts":300,"ti":30,"tf":12,"tp":"100 0 0"}"#)
        Self.advance(animator)
        XCTAssertEqual(animator.worlds, animator.skeleton.bindWorld, "the first frame has no physics")

        // The object moves 10 right: 70 % of it stays behind, the spring's velocity 7·300/60.
        let moved = ScenePuppetTests.translation(SIMD3(10, 0, 0))
        Self.advance(animator, world: moved)
        var offset = -7.0 + 35.0 / 60
        XCTAssertEqual(Double(animator.worlds[1].columns.3.x), 100 + offset, accuracy: 1e-4)
        XCTAssertEqual(animator.worlds[1].columns.3.y, 0, accuracy: 1e-5)
        XCTAssertEqual(animator.worlds[2], animator.worlds[1] * animator.skeleton.bindLocal[2], "the child follows")
        var velocity = 35.0 * (1 - 12.0 / 60)
        XCTAssertEqual(Double(animator.physics?.states[1].velocity.x ?? 0), velocity, accuracy: 1e-4)

        // Still: the bone moved as far as its offset, so the offset stays; the spring speeds it back.
        Self.advance(animator, world: moved)
        velocity -= offset * 5
        offset += velocity / 60
        velocity *= 1 - 12.0 / 60
        XCTAssertEqual(Double(animator.worlds[1].columns.3.x), 100 + offset, accuracy: 1e-4)
        XCTAssertEqual(Double(animator.physics?.states[1].velocity.x ?? 0), velocity, accuracy: 1e-3)
    }

    /// A rigid offset under gravity (`m` 2: 2000 units/s² along `gd`) and friction (`tf` 30), and
    /// an impulse damped by friction (`tf` 6); `ti` 100 keeps the whole offset.
    func testRigidTranslationGravityAndDamping() throws {
        let falling = try Self.animator(#"{"re":true,"t":true,"ti":100,"tf":30,"ge":true,"gd":"0 -1 0","m":2,"tp":"100 0 0"}"#)
        Self.advance(falling)
        Self.advance(falling)
        let firstFall: Double = -2000.0 / 3600.0
        XCTAssertEqual(Double(falling.worlds[1].columns.3.y), firstFall, accuracy: 1e-4)
        Self.advance(falling)
        // The velocity halves every frame (30/60), then gravity adds 2000/60 again.
        let secondFallSpeed: Double = 5000.0 / 60.0
        let secondFall: Double = -secondFallSpeed / 60.0
        XCTAssertEqual(Double(falling.worlds[1].columns.3.y), secondFall, accuracy: 1e-4)
        XCTAssertEqual(falling.worlds[1].columns.3.x, 100, accuracy: 1e-4)

        let pushed = try Self.animator(#"{"re":true,"t":true,"ti":100,"tf":6,"tp":"100 0 0"}"#)
        Self.advance(pushed)
        pushed.perform(.physicsImpulse(bone: 1, linear: SIMD3(60, 0, 0), angularDegrees: .zero))
        Self.advance(pushed)
        XCTAssertEqual(pushed.worlds[1].columns.3.x, 101, accuracy: 1e-4)
        Self.advance(pushed)
        let pushedTwice: Float = 101.9
        XCTAssertEqual(pushed.worlds[1].columns.3.x, pushedTwice, accuracy: 1e-4)
        let dampedVelocity: Float = 60 * 0.81
        let pushedVelocity: Float = pushed.physics?.states[1].velocity.x ?? 0
        XCTAssertEqual(pushedVelocity, dampedVelocity, accuracy: 1e-3)
    }

    /// `tm` caps the offset at `tm` times the object's mean scale.
    func testMaximumDistanceScalesWithTheObject() throws {
        let animator = try Self.animator(#"{"re":true,"t":true,"ti":100,"tm":0.5,"tp":"100 0 0"}"#)
        let scaled = simd_float4x4(diagonal: SIMD4(2, 2, 2, 1))
        Self.advance(animator, world: scaled)
        animator.perform(.physicsImpulse(bone: 1, linear: SIMD3(600, 0, 0), angularDegrees: .zero))
        Self.advance(animator, world: scaled)
        // 10 world units capped to 0.5 × 2, half that in the bone's model space.
        XCTAssertEqual(animator.worlds[1].columns.3.x, 100.5, accuracy: 1e-4)
    }

    /// A rigid bone under gravity: the tip's target is pulled across it by `m` (10), the lag's
    /// turn is taken `dist · (1 − ri/100) · π/180` of the way, a frame at 60 fps applies it all.
    func testRigidRotationFallsUnderGravity() throws {
        let animator = try Self.animator(#"{"re":true,"r":true,"ri":0,"rf":0,"ge":true,"gd":"0 -1 0","m":10,"tp":"100 0 0"}"#)
        Self.advance(animator)
        var angle = 0.0, velocity = 0.0
        for frame in 2...4 {
            // The target is 10·cos(angle) across a 100-long tip; the lag's the same distance.
            let across = 10 * cos(angle)
            velocity -= atan(across / 100) * min(across * Self.degrees, 1)
            angle += velocity
            Self.advance(animator)
            XCTAssertEqual(Double(Self.angle(animator)), angle, accuracy: 1e-4, "frame \(frame)")
        }
        XCTAssertLessThan(angle, -0.05, "it swings down")
    }

    /// A spring turned by an angular impulse: the impulse is the angular velocity, the spring
    /// (`rs` 300 °/s per radian) pulls back, friction (`rf` 6) slows it; a reset stops it.
    func testSpringRotationImpulseAndReset() throws {
        let animator = try Self.animator(#"{"se":true,"r":true,"ri":100,"rs":300,"rf":6,"tp":"100 0 0"}"#)
        Self.advance(animator)
        animator.perform(.physicsImpulse(bone: 1, linear: .zero, angularDegrees: SIMD3(0, 0, 30)))
        Self.advance(animator)
        var angle = 30 * Self.degrees
        XCTAssertEqual(Double(Self.angle(animator)), angle, accuracy: 1e-5)
        var velocity = angle * 0.9
        velocity -= angle * (300 * Self.degrees / 60)
        angle += velocity
        Self.advance(animator)
        XCTAssertEqual(Double(Self.angle(animator)), angle, accuracy: 1e-4)
        XCTAssertEqual(Double(animator.physics?.states[1].angularVelocity.angle ?? 0), velocity * 0.9, accuracy: 1e-4)

        animator.perform(.resetPhysics(bone: 1))
        XCTAssertEqual(animator.physics?.states[1], SceneBonePhysics.State())
        Self.advance(animator)
        XCTAssertEqual(Self.angle(animator), 0, accuracy: 1e-6, "back at rest")
    }

    /// `la` holds the angle in its range and takes the excess off the angular velocity; a
    /// locked axis stays 0.
    func testAngleLimitsAndLockedAxes() throws {
        let limited = try Self.animator(#"{"re":true,"r":true,"ri":100,"la":true,"lamin":"0 0 -0.5","lamax":"0 0 0.5","tp":"100 0 0"}"#)
        Self.advance(limited)
        limited.perform(.physicsImpulse(bone: 1, linear: .zero, angularDegrees: SIMD3(0, 0, 60)))
        Self.advance(limited)
        XCTAssertEqual(Self.angle(limited), 0.5, accuracy: 1e-5)
        XCTAssertEqual(limited.physics?.states[1].angularVelocity.angle ?? 0, 0.5, accuracy: 1e-4)
        Self.advance(limited)
        XCTAssertEqual(Self.angle(limited), 0.5, accuracy: 1e-5)
        XCTAssertEqual(limited.physics?.states[1].angularVelocity.angle ?? 1, 0, accuracy: 1e-3)

        let locked = try Self.animator(#"{"se":true,"r":true,"ri":100,"rax":true,"ray":true,"raz":false,"tp":"100 0 0"}"#)
        Self.advance(locked)
        locked.perform(.physicsImpulse(bone: 1, linear: .zero, angularDegrees: SIMD3(0, 0, 30)))
        Self.advance(locked)
        XCTAssertEqual(Self.angle(locked), 0, accuracy: 1e-6)
    }

    /// The helpers agree with each other: the Euler quaternion and matrix are one rotation, the
    /// angles read back, and the alignment takes one vector to the other.
    func testRotationHelpers() {
        let angles = SIMD3<Float>(0.3, -0.2, 1.1)
        let matrix = SceneBonePhysicsMath.euler(angles)
        let fromQuaternion = simd_float3x3(SceneBonePhysicsMath.quaternion(euler: angles))
        for column in 0..<3 {
            XCTAssertLessThan(simd_length(matrix[column] - fromQuaternion[column]), 1e-5)
        }
        XCTAssertLessThan(simd_length(SceneBonePhysicsMath.angles(matrix) - angles), 1e-5)
        let a = simd_normalize(SIMD3<Float>(1, 2, 0.5)), b = simd_normalize(SIMD3<Float>(-0.3, 1, 2))
        XCTAssertLessThan(simd_length(SceneBonePhysicsMath.alignment(from: a, to: b).act(a) - b), 1e-5)
        XCTAssertLessThan(simd_length(SceneBonePhysicsMath.alignment(from: a, to: -a).act(a) + a), 1e-5)
        let wrapped: Float = 4 - 2 * Float.pi
        XCTAssertEqual(SceneBonePhysicsMath.wrap(4), wrapped, accuracy: 1e-5)
        XCTAssertEqual(SceneBonePhysicsMath.wrap(-4), 2 * .pi - 4, accuracy: 1e-5)
    }

    /// The library's physics bones (17 in six rigs: the Samurai's cape and strap, the wires of
    /// 2321732083, 2949765643's hanging parts, 3159348391's ears and body) play 10 s of their
    /// first clip while the object swings: every bone stays finite, the limited ones in their
    /// limits, and the simulated ones move off their animated pose. Skipped without the library.
    func testLibraryPhysicsBonesPlay() throws {
        let rigs = ["2321732083/models/samurai_puppet.mdl": 5, "2321732083/models/wires_puppet.mdl": 1,
                    "2949765643/models/09724_puppet.mdl": 4, "2949765643/models/09728_puppet.mdl": 4,
                    "3159348391/models/boxy_boy/boxy_boy.mdl": 1, "3159348391/models/parappa/parappa.mdl": 2]
        var found = 0
        for (path, count) in rigs.sorted(by: { $0.key < $1.key }) {
            guard let url = LightingLibraryDecodeTests.roots.map({ $0.appending(path: path) })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
            found += 1
            let model = try MDLReader.read(Data(contentsOf: url))
            let skeleton = try XCTUnwrap(model.skeleton, path)
            let physics = try XCTUnwrap(SceneBonePhysics(skeleton), path)
            let simulated = physics.constraints.indices.filter { physics.constraints[$0] != nil }
            XCTAssertEqual(simulated.count, count, path)
            let clips = model.animations ?? []
            let layers = try JSONDecoder().decode([WEAnimationLayer].self, from: Data(
                (clips.first.map { #"[{"animation": \#($0.id)}]"# } ?? "[]").utf8))
            let animator = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: layers)
            // The same rig without its physics: the pose the animation alone gives.
            let still = ScenePuppetAnimator(skeleton: MDLSkeleton(version: skeleton.version, bones: skeleton.bones.map {
                var bone = $0
                bone.properties = ""
                return bone
            }), clips: clips, layers: layers)
            var moved = Set<Int>()
            for frame in 0..<600 {
                let swing = ScenePuppetTests.translation(SIMD3(Float(sin(Double(frame) / 20)) * 80, 0, 0))
                Self.advance(animator, world: swing)
                still.advance(delta: Self.delta, values: EmptySceneValues())
                XCTAssertTrue(animator.worlds.allSatisfy { m in
                    [m.columns.0, m.columns.1, m.columns.2, m.columns.3].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                }, "\(path) frame \(frame)")
                for bone in simulated {
                    let constraint = try XCTUnwrap(physics.constraints[bone])
                    let angles = try XCTUnwrap(animator.physics?.states[bone].angles)
                    if constraint.flags.contains(.limitAngles) {
                        XCTAssertTrue(all(angles .>= constraint.minAngles - 1e-4) && all(angles .<= constraint.maxAngles + 1e-4),
                                      "\(path) bone \(bone) frame \(frame): \(angles)")
                    }
                    if simd_length(animator.worlds[bone].columns.3 - still.worlds[bone].columns.3) > 1e-3
                        || simd_length(animator.worlds[bone].columns.0 - still.worlds[bone].columns.0) > 1e-4 { moved.insert(bone) }
                }
            }
            XCTAssertEqual(moved, Set(simulated), "\(path): every physics bone moves")
        }
        try XCTSkipIf(found == 0, "wallpaper library not present")
    }

    // MARK: - Scripts

    /// `applyBonePhysicsImpulse` and `resetBonePhysicsSimulation` reach the animator as commands
    /// for one bone, by index or name (an empty name is the first bone); other calls do nothing.
    func testScriptCalls() throws {
        _ = try Fixtures.assets()
        var image = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        image.rig = SceneScriptRigTests.rig
        let plain = SceneScriptObjectDescription.make(.image, id: 6, name: "plain")
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [image, plain])))
        f.runtime.load()
        f.evaluate("""
            var puppet = thisScene.getLayer('puppet'), plain = thisScene.getLayer('plain');
            puppet.applyBonePhysicsImpulse('arm', new Vec3(1, 2, 3), new Vec3(0, 0, 45));
            puppet.applyBonePhysicsImpulse(9, new Vec3(1, 0, 0), new Vec3(0, 0, 0));
            puppet.applyBonePhysicsImpulse(2, new Vec3(1, 0, 0));
            puppet.resetBonePhysicsSimulation('');
            puppet.resetBonePhysicsSimulation('hand');
            puppet.resetBonePhysicsSimulation();
            plain.applyBonePhysicsImpulse(0, new Vec3(1, 0, 0), new Vec3(0, 0, 0));
            plain.resetBonePhysicsSimulation(0);
            """)
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands: [SceneScriptRigCommand] = f.host.takeCommands().compactMap { command in
            if case .rig(_, let rig) = command { return rig }
            return nil
        }
        XCTAssertEqual(commands, [.physicsImpulse(bone: 1, linear: SIMD3(1, 2, 3), angularDegrees: SIMD3(0, 0, 45)),
                                  .resetPhysics(bone: 0), .resetPhysics(bone: 2)])

        XCTAssertEqual(SceneScriptRigLayout.decode(.rigBonePhysicsImpulse, numbers: [1, 1, 2, 3, 0, 0, 45], strings: []),
                       .physicsImpulse(bone: 1, linear: SIMD3(1, 2, 3), angularDegrees: SIMD3(0, 0, 45)))
        XCTAssertNil(SceneScriptRigLayout.decode(.rigBonePhysicsImpulse, numbers: [1, .nan, 2, 3, 0, 0, 45], strings: []))
        XCTAssertNil(SceneScriptRigLayout.decode(.rigBonePhysicsImpulse, numbers: [1, 1, 2, 3], strings: []))
        XCTAssertEqual(SceneScriptRigLayout.decode(.rigBonePhysicsReset, numbers: [2], strings: []), .resetPhysics(bone: 2))
        XCTAssertNil(SceneScriptRigLayout.decode(.rigBonePhysicsReset, numbers: [-1], strings: []))
    }
}
