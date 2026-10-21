import XCTest
import simd
@testable import OWESceneEditing

/// Puppet Warp's kinematic chains in the editor (docs/models-plan.md §2.16): WE 2.8.0.42's
/// capture 534 (`ik_arm`, `ik_norot`) and 536 (`rope_nostretch_free`) open with their chains and
/// controllers and save back, and the preview's solver lays an out-of-reach chain straight
/// toward its target as the player does.
final class PuppetKinematicsTests: XCTestCase {
    private static func rig(_ path: String) throws -> PuppetDocument {
        let data = try Data(contentsOf: PuppetFixtureRigTests.models.appending(path: path))
        return try PuppetMDLReader.read(data, imageSize: SIMD2(512, 256), sourcePath: "models/arm_puppet.mdl")
    }

    func testWEsChainsOpenAndSaveBack() throws {
        let arm = try Self.rig("PuppetIK534/ik_arm.mdl")
        let ik = try XCTUnwrap(arm.bones[3].ik)
        XCTAssertEqual(ik.limbDepth, 2)
        XCTAssertTrue(ik.rotateWhenOverstretched)
        XCTAssertFalse(try XCTUnwrap(Self.rig("PuppetIK534/ik_norot.mdl").bones[3].ik).rotateWhenOverstretched)
        XCTAssertNil(arm.bones[3].otherProperties["ik"], "the chain's keys are the chain's")
        let reopened = try PuppetMDLReader.read(try PuppetMDLWriter.write(arm), imageSize: SIMD2(512, 256))
        let again = try XCTUnwrap(reopened.bones[3].ik)
        XCTAssertEqual(again.limbDepth, ik.limbDepth)
        XCTAssertEqual(try XCTUnwrap(again.orientationRest).x, try XCTUnwrap(ik.orientationRest).x, accuracy: 1e-3)
        for frame in stride(from: Float(0), through: 60, by: 5) {
            XCTAssertEqual(again.key(.target, clip: 28, at: frame).offset.y, ik.key(.target, clip: 28, at: frame).offset.y,
                           accuracy: 1e-2, "frame \(frame)")
        }

        let rope = try Self.rig("PuppetRope536/rope_nostretch_free.mdl")
        let chain = try XCTUnwrap(rope.bones[4].ik)
        XCTAssertEqual(chain.behavior, .rope)
        XCTAssertEqual(chain.limbDepth, 4)
        XCTAssertTrue(chain.gravity)
        XCTAssertFalse(chain.stretch)
        XCTAssertTrue(chain.freeEndpoint)
        XCTAssertEqual(chain.mass, 600)
        XCTAssertEqual(chain.friction, 5)
        let layout = PuppetKinematicsLayout(rope)
        XCTAssertEqual(layout.sets.map(\.bone), [0], "a rope's set is on its root")
        XCTAssertEqual(layout.sets.first?.joints.first?.flags, 0x5)
        XCTAssertEqual(layout.links.map(\.type), [0], "a rope has no orientation controller")
    }

    func testThePreviewLaysAnOutOfReachChainStraightTowardItsTarget() throws {
        let arm = try Self.rig("PuppetIK534/ik_arm.mdl")
        let solver = try XCTUnwrap(PuppetIKSolver(arm))
        solver.begin(links: solver.layout.links.indices.map { solver.layout.linkPose($0, document: arm, clip: 28, frame: 30) },
                     delta: 1 / 30)
        let worlds = solver.worlds(locals: arm.restLocals.map(\.matrix))
        func at(_ bone: Int) -> SIMD2<Float> { PuppetMath.origin(of: worlds[bone]) }
        let chain = atan2(at(3).y - at(1).y, at(3).x - at(1).x) * 180 / .pi
        XCTAssertEqual(chain, 33.62, accuracy: 0.05, "WE's peak, atan(150.19 / 225.84)")
        XCTAssertEqual(atan2(at(2).y - at(1).y, at(2).x - at(1).x) * 180 / .pi, chain, accuracy: 0.01)
        XCTAssertEqual(atan2(worlds[3].columns.0.y, worlds[3].columns.0.x) * 180 / .pi, chain, accuracy: 0.05,
                       "Rotate when overstretched turns the hand all the way")
    }
}
