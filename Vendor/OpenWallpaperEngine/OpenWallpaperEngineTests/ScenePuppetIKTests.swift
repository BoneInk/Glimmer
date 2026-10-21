import XCTest
import simd
@testable import OpenWallpaperEngine

/// Puppet Warp inverse kinematics against WE 2.8.0.42's capture 534 (`Tests/Fixtures/Models/
/// PuppetIK534`; we-test-wp-images, tools/peer/requests/owe-beta7/models-open/534-ik): a 4-bone
/// chain (root, Bone 2, Bone 3, `hand`) whose hand has the "Inverse kinematics arm/leg" preset
/// (limb depth 2, orientation controller on), its IK target keyed 0 → +150 → 0 px up over a 2 s
/// loop. `ik_arm` turns the hand when overstretched (`ikr`), `ik_norot` doesn't. The chain is
/// 225.84 px long and the target never nearer than that to Bone 2, so WE draws it straight,
/// pointing at the target, in every still (docs/models-plan.md §2.16).
final class ScenePuppetIKTests: XCTestCase {
    private static func model(_ name: String) throws -> MDLModel {
        try MDLReader.read(try Fixtures.data("Models/PuppetIK534/\(name).mdl"))
    }

    private static func position(_ m: simd_float4x4) -> SIMD2<Float> { SIMD2(m.columns.3.x, m.columns.3.y) }

    private static func degrees(_ v: SIMD2<Float>) -> Float { atan2(v.y, v.x) * 180 / .pi }

    /// The direction of the segment from `a` to `b`, in degrees, y up.
    private static func angle(_ worlds: [simd_float4x4], _ a: Int, _ b: Int) -> Float {
        degrees(position(worlds[b]) - position(worlds[a]))
    }

    /// A bone's x axis, in degrees.
    private static func axis(_ worlds: [simd_float4x4], _ bone: Int) -> Float {
        degrees(SIMD2(worlds[bone].columns.0.x, worlds[bone].columns.0.y))
    }

    private struct Sample {
        var chain: Float
        var bone3: Float
        var hand: Float
        var worlds: [simd_float4x4]
    }

    /// Two seconds of the clip at 120 frames a second.
    private static func play(_ name: String) throws -> [Sample] {
        let model = try model(name)
        let skeleton = try XCTUnwrap(model.skeleton)
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: model.animations ?? [],
                                           layers: [WEAnimationLayer(animation: 28)])
        XCTAssertNotNil(animator.ik)
        return (0..<240).map { _ in
            animator.advance(delta: 1 / 120, values: EmptySceneValues())
            let worlds = animator.worlds
            return Sample(chain: angle(worlds, 1, 3), bone3: angle(worlds, 2, 3), hand: axis(worlds, 3), worlds: worlds)
        }
    }

    /// WE's stills (`stills/`, RenderDoc at about 0.25, 0.5, 0.75, 1 and 1.5 s): the line from
    /// the Bone 2 joint's tick to the hand joint's, and the hand's lower edge, measured at the
    /// pixels. The stills' clock and the clip's differ by up to 0.13 s, so each is matched to the
    /// frame of the clip where the chain points the same way.
    private static let armStills: [(chain: Float, hand: Float)] = [(0.58, 0.00), (10.21, 1.62), (26.89, 27.25),
                                                                  (33.62, 33.33), (28.27, 27.72)]
    private static let norotStills: [(chain: Float, hand: Float)] = [(2.63, 0), (16.07, 0), (29.49, 0), (34.52, 0),
                                                                    (25.55, 0)]

    private func assertMatches(_ samples: [Sample], _ stills: [(chain: Float, hand: Float)], _ name: String) {
        for still in stills {
            let nearest = samples.min { abs($0.chain - still.chain) < abs($1.chain - still.chain) }!
            XCTAssertEqual(nearest.chain, still.chain, accuracy: 1, "\(name): the clip reaches the still's \(still.chain)°")
            XCTAssertEqual(nearest.hand, still.hand, accuracy: 1.2, "\(name) at \(still.chain)°: the hand")
        }
    }

    func testTheChainLiesStraightTowardTheTargetAndTheRootStays() throws {
        for name in ["ik_arm", "ik_norot"] {
            let samples = try Self.play(name)
            for sample in samples {
                XCTAssertEqual(sample.bone3, sample.chain, accuracy: 0.01, "\(name): Bone 2 and Bone 3 in line")
                XCTAssertEqual(Self.position(sample.worlds[0]).x, -224.579, accuracy: 1e-3)
                XCTAssertEqual(Self.position(sample.worlds[1]).x, -112.289, accuracy: 1e-3, "\(name): Bone 2 stays")
                XCTAssertEqual(Self.position(sample.worlds[1]).y, 0, accuracy: 1e-3)
                XCTAssertEqual(simd_length(Self.position(sample.worlds[3]) - Self.position(sample.worlds[1])), 225.84,
                               accuracy: 0.01, "\(name): the chain keeps its length")
            }
            // The target peaks at 150.19 px up at frame 30: atan(150.19 / 225.84).
            let peak = try XCTUnwrap(samples.map(\.chain).max())
            XCTAssertEqual(peak, 33.62, accuracy: 0.05, name)
        }
    }

    func testRotateWhenOverstretchedTurnsTheHandAsInWE() throws {
        let samples = try Self.play("ik_arm")
        assertMatches(samples, Self.armStills, "ik_arm")
        // ikrd 25: the hand turns by min((overstretch − 1) / 25, 1) of the way to the target.
        for sample in samples {
            let over = 225.84 / cos(sample.chain * .pi / 180) - 225.84
            let t = over * over > 1 ? min((over - 1) / 25, 1) : 0
            XCTAssertEqual(sample.hand, sample.chain * t, accuracy: 0.05)
        }
    }

    func testWithoutRotateTheHandKeepsItsTargetsOrientation() throws {
        let samples = try Self.play("ik_norot")
        assertMatches(samples, Self.norotStills, "ik_norot")
        for sample in samples { XCTAssertEqual(sample.hand, 0, accuracy: 1e-3) }
    }

    /// WE solves only on the update's path with animation layers: without one the rig rests.
    func testWithoutALayerTheSolverDoesNotRun() throws {
        let model = try Self.model("ik_arm")
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: model.animations ?? [],
                                           layers: [])
        for _ in 0..<10 { animator.advance(delta: 1 / 30, values: EmptySceneValues()) }
        XCTAssertEqual(Self.position(animator.worlds[3]), SIMD2(113.551, 0), accuracy: 1e-3)
    }

    // MARK: - Reach

    /// The capture's skeleton with its target and orientation controller placed by hand, posed
    /// `frames` times (the chain starts each frame where the last left it, as WE's does).
    private static func solve(target: SIMD2<Float>, pole: SIMD2<Float>, ikr: Bool = true,
                              frames: Int = 1) throws -> [simd_float4x4] {
        let skeleton = try XCTUnwrap(try model(ikr ? "ik_arm" : "ik_norot").skeleton)
        let ik = try XCTUnwrap(ScenePuppetIK(skeleton))
        let rig = SceneSkeleton(skeleton)
        func link(_ p: SIMD2<Float>) -> SceneBoneTransform {
            SceneBoneTransform(translation: SIMD3(p, 0), rotation: SceneBonePhysicsMath.identity, scale: SIMD3(repeating: 1))
        }
        var worlds: [simd_float4x4] = []
        for _ in 0..<frames {
            ik.beginFrame(links: [link(pole), link(target)], delta: 1 / 30, objectWorld: matrix_identity_float4x4)
            worlds = rig.worlds(locals: rig.restLocal, ik: ik)
        }
        return worlds
    }

    func testAReachableTargetBendsTheChainTowardTheOrientationController() throws {
        let target = SIMD2<Float>(40, 60)
        for poleUp in [true, false] {
            let pole = SIMD2<Float>(0.63, poleUp ? 112.9 : -112.9)
            let worlds = try Self.solve(target: target, pole: pole, frames: 3)
            let root = Self.position(worlds[1]), elbow = Self.position(worlds[2]), hand = Self.position(worlds[3])
            XCTAssertEqual(root, SIMD2(-112.289, 0), accuracy: 1e-3, "the root stays")
            XCTAssertLessThan(simd_length(hand - target), 0.32, "the effector reaches the target (WE's √0.1)")
            XCTAssertEqual(simd_length(elbow - root), 112.29, accuracy: 0.01)
            XCTAssertEqual(simd_length(hand - elbow), 113.55, accuracy: 0.01)
            // The elbow's side of the root-to-target line is the controller's.
            let line = target - root
            let side = line.x * (elbow - root).y - line.y * (elbow - root).x
            XCTAssertEqual(side > 0, poleUp, "the bend follows the orientation controller")
            // Bone 2 and Bone 3 point down their solved segments.
            XCTAssertEqual(Self.axis(worlds, 1), Self.angle(worlds, 1, 2), accuracy: 0.01)
            XCTAssertEqual(Self.axis(worlds, 2), Self.angle(worlds, 2, 3), accuracy: 0.01)
            // Within reach the hand takes the target's orientation, `ikr` or not.
            XCTAssertEqual(Self.axis(worlds, 3), 0, accuracy: 1e-3)
        }
    }

    func testAnOverstretchedChainPointsAtTheTargetAndTurnsTheHandWithIt() throws {
        // 10 px past reach: (10 − 1) / 25 of the way; 40 px: all the way.
        for (beyond, turn) in [(Float(10), Float(9) / 25), (40, 1)] {
            let direction = SIMD2<Float>(cos(0.5), sin(0.5))
            let target = SIMD2<Float>(-112.289, 0) + direction * (225.84 + beyond)
            let worlds = try Self.solve(target: target, pole: SIMD2(0.63, 112.9))
            XCTAssertEqual(Self.angle(worlds, 1, 2), 0.5 * 180 / .pi, accuracy: 0.01)
            XCTAssertEqual(Self.angle(worlds, 2, 3), 0.5 * 180 / .pi, accuracy: 0.01)
            XCTAssertEqual(Self.axis(worlds, 3), 0.5 * 180 / .pi * turn, accuracy: 0.05)
            let still = try Self.solve(target: target, pole: SIMD2(0.63, 112.9), ikr: false)
            XCTAssertEqual(Self.axis(still, 3), 0, accuracy: 1e-3)
        }
    }
}

private func XCTAssertEqual(_ a: SIMD2<Float>, _ b: SIMD2<Float>, accuracy: Float, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(simd_length(a - b), accuracy, "\(a) vs \(b) \(message)", file: file, line: line)
}
