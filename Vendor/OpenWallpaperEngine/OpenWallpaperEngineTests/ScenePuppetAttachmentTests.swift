import XCTest
import simd
@testable import OpenWallpaperEngine

/// Bone attachments (docs/models-plan.md §2.6, §5.15): `attachment` decoded on every object, and
/// `world = parentWorld · boneWorld[bone] · attachment matrix · local` in both hierarchies.
final class ScenePuppetAttachmentTests: XCTestCase {
    private func object(_ json: String) throws -> WESceneObject {
        try JSONDecoder().decode(WESceneObject.self, from: Data(json.utf8))
    }

    /// An image, not only a model, carries `attachment`.
    func testEveryObjectDecodesItsAttachment() throws {
        let sword = try object(#"{"id": 258, "parent": 25, "attachment": "правая рука", "image": "models/меч.json"}"#)
        XCTAssertEqual(sword.attachment, "правая рука")
        XCTAssertNil(try object(#"{"id": 1, "image": "a.json"}"#).attachment)
        let hierarchy = SceneTransformHierarchy3D(objects: [sword])
        XCTAssertEqual(hierarchy.nodes["258"]?.attachment, "правая рука")
    }

    /// The attachment sits between the parent's world and the child's local, in 2D and in 3D.
    func testTheChildHangsFromThePosedBone() throws {
        let parent = try object(#"{"id": 1, "origin": "100 200 0", "image": "p.json"}"#)
        let child = try object(#"{"id": 2, "parent": 1, "attachment": "hand", "origin": "5 0 0", "image": "c.json"}"#)
        let skeleton = MDLSkeleton(version: 1, bones: [
            MDLBone(name: "root", flags: 1, parent: 0xFFFF_FFFF, matrix: matrix_identity_float4x4, properties: ""),
            MDLBone(name: "arm", flags: 1, parent: 0, matrix: ScenePuppetTests.translation(SIMD3(30, 0, 0)), properties: ""),
        ])
        let clip = SceneAnimationLayersTests.clip(id: 1, bones: 2, pose: { _ in
            MDLBonePose(position: SIMD3(0, 40, 0), euler: SIMD3(0, 0, .pi / 2), scale: SIMD3(repeating: 1))
        })
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: [clip], layers: [WEAnimationLayer(animation: 1)])
        animator.advance(delta: 0, values: EmptySceneValues())
        let attachments = [MDLAttachment(bone: 1, name: "hand", matrix: ScenePuppetTests.translation(SIMD3(0, 10, 0)))]
        // Root at (0, 40) turned 90°; the arm 40 up from it, turned again: 180° in all.
        let bone = animator.worlds[1]
        let hand = try XCTUnwrap(ScenePuppetAttachments.matrix(named: "hand", in: attachments, worlds: animator.worlds))
        XCTAssertEqual(hand, bone * ScenePuppetTests.translation(SIMD3(0, 10, 0)))
        XCTAssertNil(ScenePuppetAttachments.matrix(named: "foot", in: attachments, worlds: animator.worlds))

        let hierarchy = SceneTransformHierarchy(objects: [parent, child])
        let world = hierarchy.world(of: "2", attachments: { child, parent, name in
            XCTAssertEqual([child, parent, name], ["2", "1", "hand"])
            return ScenePuppetAttachments.affine(hand)
        })
        let expected = SIMD4<Float>(100, 200, 0, 0) + hand * SIMD4(5, 0, 0, 1)
        XCTAssertEqual(world.translation.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(world.translation.y, expected.y, accuracy: 1e-3)
        XCTAssertEqual(hierarchy.world(of: "2").translation, SIMD2(105, 200), "without attachments: the parent's origin")
        // The space the renderer draws the child's own transform in carries the attachment too
        // (the draw used the parents' world alone, so the witcher's sword hung from his origin).
        let space = hierarchy.attachedParentWorld(of: "2", attachments: { _, _, _ in ScenePuppetAttachments.affine(hand) })
        let drawn = space * SceneAffineTransform(try XCTUnwrap(hierarchy.nodes["2"]?.local))
        XCTAssertEqual(drawn.translation.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(drawn.translation.y, expected.y, accuracy: 1e-3)

        let hierarchy3D = SceneTransformHierarchy3D(objects: [parent, child])
        struct Provider: SceneAttachmentProviding {
            let matrix: simd_float4x4
            func attachmentWorld(_ object: SceneAttachedObject) -> simd_float4x4? { matrix }
        }
        let world3D = hierarchy3D.world(of: "2", attachments: Provider(matrix: hand))
        XCTAssertEqual(world3D.columns.3.x, expected.x, accuracy: 1e-3)
        XCTAssertEqual(world3D.columns.3.y, expected.y, accuracy: 1e-3)
    }

    /// The library's attachment: the witcher's sword (3803167460) on "правая рука", bone 24, which
    /// the rig's layers move.
    func testTheWitchersSwordFollowsTheHand() throws {
        let directory = LibrarySweepTests.libraryRoot.appending(path: "3803167460", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path), "wallpaper library not present")
        let data = try Data(contentsOf: directory.appending(path: "scene.json"))
        let document = try decodeTolerant(WEScene.self, from: data)
        let sword = try XCTUnwrap(document.objects.first { $0.id == 258 })
        let witcher = try XCTUnwrap(document.objects.first { $0.id == 25 })
        XCTAssertEqual(sword.attachment, "правая рука")
        let model = try MDLModel.load(path: "models/ведьмак розбивpng_puppet.mdl", package: nil, directory: directory)
        let animator = ScenePuppetAnimator(skeleton: try XCTUnwrap(model.skeleton), clips: model.animations ?? [],
                                           layers: witcher.animationLayers)
        var hands: [SIMD4<Float>] = []
        for _ in 0..<3 {
            animator.advance(delta: 0.4, values: EmptySceneValues())
            let hand = try XCTUnwrap(ScenePuppetAttachments.matrix(named: "правая рука", in: model.attachments ?? [],
                                                                   worlds: animator.worlds))
            hands.append(hand.columns.3)
        }
        XCTAssertGreaterThan(simd_distance(hands[0], hands[2]), 0.5, "the hand moves with the layers")
    }
}
