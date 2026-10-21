import simd
import XCTest
@testable import OpenWallpaperEngine

/// WE 2.8.0.42 capture 538: the bars puppet (`Models/PuppetHitBox538`, bones "red", "blue" and an
/// unweighted "anchor"), a 512 × 256 image layer centred at (960, 540) of a 1920 × 1080 scene. WE's
/// editor compiles a hit box per bone into the skeleton's per-bone block (`MDLSkeleton.boneVectors`):
/// the bounds of the vertices the bone moves, in its frame, and a 1-unit box for a bone that moves
/// none (Show Hitboxes draws it as a dot). Clicks logged in Run Preview named the bone under them:
/// local (131, 125) "red", (383, 125) "blue", and (257, 128), the gap between the bars, "red",
/// because red's box reaches over it.
final class ScenePuppetHitBoxCaptureTests: XCTestCase {
    private func layer() throws -> SceneScriptCursorLayer {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/PuppetHitBox538/bars_puppet.mdl"))
        let skeleton = try XCTUnwrap(model.skeleton)
        XCTAssertEqual(skeleton.bones.map(\.name), ["red", "blue", "anchor"])
        let shape = try XCTUnwrap(SceneScriptCursorShape.puppet(model), "WE's editor writes the per-bone block")
        XCTAssertEqual(shape.hitBoxes.map(\.name), ["red", "blue", "anchor"])
        let anchor = try XCTUnwrap(shape.hitBoxes.last)
        XCTAssertEqual(anchor.halfExtents, SIMD3(repeating: 0.5), "an unweighted bone's box is a dot")
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: [], layers: [])
        let world = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(960, 540, 0, 1))
        guard case .puppet(let order) = shape.kind else { throw XCTSkip("not a puppet shape") }
        return SceneScriptCursorLayer(slot: 1, worldMatrix: world, size: SIMD2(512, 256),
                                      hitBoxes: .init(boxes: shape.hitBoxes, order: order,
                                                      boneWorlds: animator.worlds.map { world * $0 }))
    }

    /// WE's logged world positions (scene pixels, y up) and the bone each click named.
    func testClicksNameTheBoneWhoseBoxIsUnderThem() throws {
        let puppet = try layer()
        for (world, name) in [(SIMD2<Float>(835.09, 542.52), "red"), (SIMD2<Float>(1087.43, 542.52), "blue"),
                              (SIMD2<Float>(961.26, 540), "red")] {
            let ray = SceneScriptCursorRay.orthographic(through: world)
            XCTAssertEqual(SceneScriptCursorHitTest.hitBox(puppet, ray: ray)?.name, name, "at \(world)")
            // The same click's local position: layer texture pixels from the top left, y down.
            let local = SceneScriptCursorHitTest.test(puppet, ray: ray, offset: .zero)
            XCTAssertTrue(local.isInside)
            XCTAssertEqual(local.localPosition.x, world.x - 704, accuracy: 0.01)
            XCTAssertEqual(local.localPosition.y, 668 - world.y, accuracy: 0.01)
        }
        // Above the bars, inside the layer: no bone's box.
        XCTAssertNil(SceneScriptCursorHitTest.hitBox(puppet, ray: .orthographic(through: SIMD2(835, 640))))
    }

    /// Show Hitboxes: red's box spans the red bar and the gap, blue's the blue bar;
    /// the unweighted anchor's is a 1-unit dot.
    func testShowHitboxesOutlinesTheBoxesTheClicksHit() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/PuppetHitBox538/bars_puppet.mdl"))
        let skeleton = try XCTUnwrap(model.skeleton)
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: [], layers: [])
        let world = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(960, 540, 0, 1))
        let outlines = ScenePuppetHitBoxOutline.outlines(layerID: "10", skeleton: skeleton, boneWorlds: animator.worlds,
                                                         world: world)
        XCTAssertEqual(outlines.map(\.name), ["red", "blue", "anchor"])
        func span(_ outline: ScenePuppetHitBoxOutline) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
            (outline.corners.reduce(SIMD2<Float>(repeating: .infinity)) { simd_min($0, $1) },
             outline.corners.reduce(SIMD2<Float>(repeating: -.infinity)) { simd_max($0, $1) })
        }
        let red = span(outlines[0]), blue = span(outlines[1]), anchor = span(outlines[2])
        for point in [SIMD2<Float>(835.09, 542.52), SIMD2<Float>(961.26, 540)] {
            XCTAssertTrue(all(point .>= red.min) && all(point .<= red.max), "\(point) in red's \(red)")
        }
        let bluePoint = SIMD2<Float>(1087.43, 542.52)
        XCTAssertTrue(all(bluePoint .>= blue.min) && all(bluePoint .<= blue.max), "in blue's \(blue)")
        let redPoint = SIMD2<Float>(835.09, 542.52)
        XCTAssertFalse(all(redPoint .>= blue.min) && all(redPoint .<= blue.max), "the red bar is outside blue's box")
        let anchorWidth: Float = anchor.max.x - anchor.min.x
        XCTAssertEqual(anchorWidth, 1, accuracy: 0.01)
    }

    /// Enter and move (button up) carry no `hitBox`; down, up and click name the bone.
    func testOnlyButtonEventsCarryTheBoneName() throws {
        let puppet = try layer()
        var pass = SceneScriptCursorPass()
        func step(_ x: Float, down: Bool) -> [String] {
            pass.update(SceneScriptCursorFrame(cursorWorldPosition: SIMD3(x, 542.52, 0), leftButtonDown: down, layers: [puppet]))
                .map { "\($0.callback.rawValue) \($0.hitBox ?? "-")" }
        }
        XCTAssertEqual(step(835.09, down: false), ["cursorEnter -", "cursorMove -"])
        XCTAssertEqual(step(835.09, down: true), ["cursorDown red"])
        XCTAssertEqual(step(835.09, down: false), ["cursorUp red", "cursorClick red"])
        XCTAssertEqual(step(1087.43, down: false), ["cursorMove -"])
        XCTAssertEqual(step(1087.43, down: true), ["cursorDown blue"])
        XCTAssertEqual(step(1087.43, down: false), ["cursorUp blue", "cursorClick blue"])
        XCTAssertEqual(step(1500, down: false), ["cursorLeave -"])
        XCTAssertEqual(step(1500, down: true), [], "no event for a click outside the layer")
    }
}
