import simd
import XCTest
@testable import OpenWallpaperEngine

/// Named hit boxes (`CursorEvent.hitBox`): a puppet's (wallpaper64.exe 0x1401fd690) and a model's
/// (0x140223810), and when the cursor pass asks for them (0x14018a276).
final class SceneScriptCursorHitBoxTests: XCTestCase {
    private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t, 1))
    }

    private func box(_ name: String, at centre: SIMD3<Float>, half: Float = 10) -> SceneScriptCursorShape.HitBox {
        SceneScriptCursorShape.HitBox(name: name, halfExtents: SIMD3(repeating: half), matrix: translation(centre))
    }

    private let down = SceneScriptCursorRay(origin: SIMD3(0, 0, 1000), direction: SIMD3(0, 0, -1))

    func testAPuppetNamesTheTopmostLimbInItsDepthOrder() {
        // Bones 0 and 1 overlap at the origin; the depth order lists 1 then 0, so 0 is on top.
        let boxes = [box("arm", at: .zero), box("body", at: .zero), box("leg", at: SIMD3(100, 0, 0))]
        let worlds = [simd_float4x4](repeating: translation(SIMD3(5, 0, 0)), count: 3)
        let puppet = SceneScriptCursorLayer(slot: 1, worldMatrix: matrix_identity_float4x4, size: SIMD2(400, 400),
                                            hitBoxes: .init(boxes: boxes, order: [1, 0, 2], boneWorlds: worlds))
        XCTAssertEqual(SceneScriptCursorHitTest.hitBox(puppet, ray: down)?.name, "arm",
                       "from the end of the order: leg misses, then arm is the first hit")
        var shifted = puppet
        shifted.hitBoxes?.order = [0, 1, 2]
        XCTAssertEqual(SceneScriptCursorHitTest.hitBox(shifted, ray: down), .init(name: "body", localPosition: nil),
                       "no local position from a puppet")
        let ray = SceneScriptCursorRay(origin: SIMD3(105, 0, 1000), direction: SIMD3(0, 0, -1))
        XCTAssertEqual(SceneScriptCursorHitTest.hitBox(shifted, ray: ray)?.name, "leg", "through the bone's world")
        let miss = SceneScriptCursorRay(origin: SIMD3(50, 0, 1000), direction: SIMD3(0, 0, -1))
        XCTAssertNil(SceneScriptCursorHitTest.hitBox(shifted, ray: miss))
    }

    func testAModelNamesTheNearestBoxAndReportsWhereTheRayEntersIt() {
        let boxes = [box("back", at: SIMD3(0, 0, -100)), box("front", at: SIMD3(0, 0, 100), half: 20)]
        let world = translation(SIMD3(0, 0, 0))
        let model = SceneScriptCursorLayer(slot: 1, worldMatrix: world, shape: .model(nil),
                                           hitBoxes: .init(boxes: boxes, order: nil, boneWorlds: [world, world]))
        let hit = SceneScriptCursorHitTest.hitBox(model, ray: down)
        XCTAssertEqual(hit?.name, "front")
        XCTAssertEqual(hit?.localPosition, SIMD3(0, 0, 20), "the entry point in the box's frame")
        let unposed = SceneScriptCursorLayer(slot: 1, worldMatrix: world, shape: .model(nil),
                                             hitBoxes: .init(boxes: boxes, order: nil, boneWorlds: []))
        XCTAssertEqual(SceneScriptCursorHitTest.hitBox(unposed, ray: down)?.name, "1", "without a pose, boxes go by index")
    }

    func testTheShapeComesFromTheSkeletonsPerBoneBlock() throws {
        var model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        XCTAssertNil(SceneScriptCursorShape.puppet(model), "no library rig has hit boxes (WE's editor compiles them into new rigs)")
        var skeleton = try XCTUnwrap(model.skeleton)
        skeleton.boneVectors = skeleton.bones.map { _ in .init(vector: SIMD3(1, 2, 3), matrix: matrix_identity_float4x4) }
        skeleton.bones[0].name = ""
        skeleton.boneIndices = (0..<UInt32(skeleton.bones.count)).reversed()
        model.skeleton = skeleton
        let shape = try XCTUnwrap(SceneScriptCursorShape.puppet(model))
        XCTAssertEqual(shape.hitBoxes.first?.name, "0", "an unnamed bone is named by its index")
        XCTAssertEqual(shape.hitBoxes.first?.halfExtents, SIMD3(1, 2, 3))
        XCTAssertEqual(shape.kind, .puppet(order: Array((0..<skeleton.bones.count).reversed())))
        skeleton.boneIndices = nil
        model.skeleton = skeleton
        XCTAssertNil(SceneScriptCursorShape.puppet(model), "without the depth order WE tries none")
    }

    func testThePassNamesHitBoxesOnlyOnButtonFramesAndWhileDragging() {
        var pass = SceneScriptCursorPass()
        let named = SceneScriptCursorLayer(slot: 3, worldMatrix: matrix_identity_float4x4, size: SIMD2(100, 100),
                                           hitBoxes: .init(boxes: [box("hand", at: .zero, half: 100)], order: [0],
                                                           boneWorlds: [matrix_identity_float4x4]))
        func step(_ x: Float, down: Bool) -> [String] {
            pass.update(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(x, 0, 0), leftButtonDown: down, layers: [named]))
                .map { "\($0.callback.rawValue) \($0.hitBox ?? "-")" }
        }
        XCTAssertEqual(step(0, down: false), ["cursorEnter -", "cursorMove -"])
        XCTAssertEqual(step(0, down: true), ["cursorDown hand"])
        XCTAssertEqual(step(10, down: true), ["cursorMove hand"], "dragging")
        XCTAssertEqual(step(10, down: false), ["cursorUp hand", "cursorClick hand"])
        XCTAssertEqual(step(20, down: false), ["cursorMove -"])
        let event = SceneScriptCursorEvent(callback: .cursorUp, slot: 3, worldPosition: .zero, localPosition: .zero, hitBox: "hand")
        XCTAssertEqual((event.inboxEvent.payload as? [String: Any])?["hitBox"] as? String, "hand")
        XCTAssertNil((SceneScriptCursorEvent(callback: .cursorUp, slot: 3, worldPosition: .zero, localPosition: .zero)
            .inboxEvent.payload as? [String: Any])?["hitBox"])
    }
}
