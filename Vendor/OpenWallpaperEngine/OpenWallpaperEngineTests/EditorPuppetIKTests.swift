import XCTest
import simd
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's kinematic chains as the player reads them: WE 2.8.0.42's capture 534
/// (`Tests/Fixtures/Models/PuppetIK534/ik_arm.mdl`, an "Inverse kinematics arm/leg" hand on a
/// 4-bone chain, its target keyed 0 → +150 → 0 px up) opens in the editor with its chain and
/// controllers, and the editor writes the IK sets, links, maps and link tracks WE's compiler
/// wrote (docs/models-plan.md §2.16); a chain made in the editor plays in the app.
final class EditorPuppetIKTests: XCTestCase {
    private static func capture() throws -> (data: Data, model: MDLModel) {
        let data = try Fixtures.data("Models/PuppetIK534/ik_arm.mdl")
        return (data, try MDLReader.read(data))
    }

    func testWEsChainOpensWithItsControllersAndSavesAsWEWroteIt() throws {
        let (data, original) = try Self.capture()
        let document = try PuppetMDLReader.read(data, imageSize: SIMD2(512, 256))
        let ik = try XCTUnwrap(document.bones[3].ik)
        XCTAssertEqual(ik.behavior, .inverseKinematics)
        XCTAssertEqual(ik.limbDepth, 2)
        XCTAssertTrue(ik.orientationController)
        XCTAssertTrue(ik.rotateWhenOverstretched)
        XCTAssertEqual(ik.fullRotationDistance, 25)
        XCTAssertEqual(try XCTUnwrap(ik.orientationRest).y, 112.9205, accuracy: 1e-3)
        XCTAssertEqual(ik.key(.target, clip: 28, at: 30).offset.y, 150.19, accuracy: 0.01, "the keyed peak")
        XCTAssertNil(document.bones[1].ik)

        let written = try MDLReader.read(try PuppetMDLWriter.write(document))
        let a = try XCTUnwrap(original.skeleton), b = try XCTUnwrap(written.skeleton)
        XCTAssertEqual(b.bones.map(\.flags), a.bones.map(\.flags), "flag 0x2 on the chain bones")
        XCTAssertEqual(b.links.map(\.bone), a.links.map(\.bone))
        XCTAssertEqual(b.links.map(\.type), a.links.map(\.type))
        for (x, y) in zip(a.links, b.links) {
            XCTAssertEqual(simd_distance(x.matrix.columns.3, y.matrix.columns.3), 0, accuracy: 1e-3)
        }
        XCTAssertEqual(b.mapIDs.map { Float(bitPattern: $0) }, a.mapIDs.map { Float(bitPattern: $0) })
        XCTAssertEqual(b.maps.map { $0.map(\.key) }, a.maps.map { $0.map(\.key) })
        XCTAssertEqual(b.ikSets.count, 1)
        let set = try XCTUnwrap(b.ikSets.first), wanted = try XCTUnwrap(a.ikSets.first)
        XCTAssertEqual(set.bone, wanted.bone)
        XCTAssertEqual(set.links, wanted.links)
        XCTAssertEqual(set.elements.map(\.bone), wanted.elements.map(\.bone))
        let joint = try XCTUnwrap(set.elements.first?.joints.first), wantedJoint = try XCTUnwrap(wanted.elements.first?.joints.first)
        XCTAssertEqual(joint.bone, wantedJoint.bone)
        XCTAssertEqual(joint.flags, wantedJoint.flags)
        XCTAssertEqual(joint.f0, wantedJoint.f0, accuracy: 1e-3)
        XCTAssertEqual(joint.bones, wantedJoint.bones)
        // The target's track, frame for frame.
        let track = try XCTUnwrap(written.animations?.first?.linkTracks?[1])
        let wantedTrack = try XCTUnwrap(original.animations?.first?.linkTracks?[1])
        XCTAssertEqual(track.samples.count, wantedTrack.samples.count)
        let worst = zip(track.samples, wantedTrack.samples).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThan(worst, 1e-3)
        let physics = try XCTUnwrap(MDLBonePhysics(properties: b.bones[3].properties))
        XCTAssertTrue(physics.flags.isSuperset(of: [.ik, .ikGravityController, .ikEndRotation]))
        XCTAssertEqual(physics.ikRotationDistance, 25)
    }

    /// A chain made in the editor: a 3-bone arm whose hand reaches for a target keyed up.
    func testAChainMadeInTheEditorPlaysInTheApp() throws {
        var document = PuppetDocument.new(imageSize: SIMD2(400, 100), material: "materials/arm.json")
        document.bones = []
        document.addBone(named: "shoulder", parent: nil, head: SIMD2(-150, 0), angle: 0)
        document.addBone(named: "elbow", parent: 0, head: SIMD2(-50, 0), angle: 0)
        document.addBone(named: "hand", parent: 1, head: SIMD2(50, 0), angle: 0)
        document.replaceMesh(PuppetMesh(vertices: [PuppetVertex(position: SIMD2(-150, -10), uv: SIMD2(0, 1)),
                                                   PuppetVertex(position: SIMD2(150, -10), uv: SIMD2(1, 1)),
                                                   PuppetVertex(position: SIMD2(0, 10), uv: SIMD2(0.5, 0))],
                                        triangles: [SIMD3(0, 1, 2)]))
        document.weights = Array(repeating: [PuppetWeight(bone: 0, weight: 1)], count: 3)
        let clip = document.addClip(named: "reach", fps: 30, frames: 30)
        var ik = PuppetBoneIK(preset: .arm)
        ik.rotateWhenOverstretched = false
        let id = document.clips[clip].id
        ik.setKey(.target, clip: id, frame: 0, to: .init(offset: SIMD2(-100, 80)))
        ik.setKey(.target, clip: id, frame: 30, to: .init(offset: SIMD2(-100, 80)))
        document.bones[2].ik = ik
        document.layers = [PuppetAnimationLayer(id: 1, name: "reach", clipID: id)]
        let model = try MDLReader.read(try PuppetMDLWriter.write(document))
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: model.animations ?? [],
                                           layers: [WEAnimationLayer(animation: id)])
        for _ in 0..<5 { animator.advance(delta: 1 / 30, values: EmptySceneValues()) }
        let hand = animator.worlds[2].columns.3, shoulder = animator.worlds[0].columns.3, elbow = animator.worlds[1].columns.3
        // The target, (−50, 80), is 128 px from the shoulder: within the arm's 200 px.
        XCTAssertLessThan(simd_distance(SIMD2(hand.x, hand.y), SIMD2(-50, 80)), 0.32)
        XCTAssertEqual(simd_distance(SIMD2(shoulder.x, shoulder.y), SIMD2(elbow.x, elbow.y)), 100, accuracy: 0.01)
        XCTAssertEqual(simd_distance(SIMD2(elbow.x, elbow.y), SIMD2(hand.x, hand.y)), 100, accuracy: 0.01)
        // The editor's preview solves it the same way.
        let solver = try XCTUnwrap(PuppetIKSolver(document))
        solver.begin(links: solver.layout.links.indices.map { solver.layout.linkPose($0, document: document, clip: id, frame: 0) },
                     delta: 1 / 30)
        var preview: [simd_float4x4] = []
        for _ in 0..<5 { preview = solver.worlds(locals: document.bones.map(\.local.matrix)) }
        for bone in 0..<3 {
            XCTAssertEqual(simd_distance(preview[bone].columns.3, animator.worlds[bone].columns.3), 0, accuracy: 0.01,
                           "bone \(bone): the preview is the player's")
        }
    }
}
