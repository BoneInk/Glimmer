import JavaScriptCore
import simd
import XCTest
@testable import OpenWallpaperEngine

/// WE's cursor ray and its model and 3D quad tests (wallpaper64.exe 0x14018e1a0, 0x140185520,
/// 0x14019d5a0) and a perspective scene's cursor order (0x1401865c0).
final class SceneScriptCursorModelHitTestTests: XCTestCase {
    private func translation(_ t: SIMD3<Float>, scale: Float = 1) -> simd_float4x4 {
        simd_float4x4(SIMD4(scale, 0, 0, 0), SIMD4(0, scale, 0, 0), SIMD4(0, 0, scale, 0), SIMD4(t, 1))
    }

    private func model(_ slot: Int, bounds: MDLBounds?, world: simd_float4x4, stops: Bool = false) -> SceneScriptCursorLayer {
        SceneScriptCursorLayer(slot: slot, worldMatrix: world, shape: .model(bounds), disablesPropagation: stops)
    }

    private let cube = MDLBounds(min: SIMD3(repeating: -50), max: SIMD3(repeating: 50))

    func testAModelsBoxIsItsMeshBounds() {
        // A cube around the model's origin is tested over −50…50 of model space (WE 2.8.0.42,
        // capture 539: both the lower-left and the upper-right quarter are hit).
        let layer = model(1, bounds: cube, world: translation(SIMD3(500, 500, 0)))
        let inside = SceneScriptCursorHitTest.test(layer, cursor: SIMD2(500, 500), offset: .zero)
        XCTAssertTrue(inside.isInside)
        XCTAssertEqual(inside.localPosition, SIMD3(0, 0, 50), "where the ray enters, from the box's centre")
        XCTAssertEqual(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(470, 460), offset: .zero).localPosition,
                       SIMD3(-30, -40, 50), "the lower-left quarter")
        XCTAssertTrue(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(549.5, 450.5), offset: .zero).isInside)
        // A ray along z exactly on a face meets 0 · ∞ = NaN in that axis's slab, and SSE's picks
        // turn that into a miss.
        XCTAssertFalse(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(550, 525), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(450, 525), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(551, 525), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(575, 575), offset: .zero).isInside,
                       "nothing past the mesh's bounds")
        // A mesh off its origin: the box follows the bounds, the local position their centre.
        let offCentre = model(1, bounds: MDLBounds(min: SIMD3(0, 0, 0), max: SIMD3(100, 20, 10)), world: translation(.zero))
        XCTAssertFalse(SceneScriptCursorHitTest.test(offCentre, cursor: SIMD2(-10, 10), offset: .zero).isInside)
        XCTAssertEqual(SceneScriptCursorHitTest.test(offCentre, cursor: SIMD2(90, 15), offset: .zero).localPosition,
                       SIMD3(40, 5, 5))
    }

    /// WE 2.8.0.42 capture 539: a unit cube around its origin (the `.mdl` is 100 units a side, at
    /// scale 0.01) seen from a camera at (0, 0, 3). Both clicks hit, at the local positions WE
    /// logged; a ray past the cube misses with a zero local position.
    func testTheCaptureCubeIsHitInEveryQuarter() throws {
        let mdl = try MDLModel(contentsOf: Fixtures.url("Models/ModelClick539/centered_cube.mdl"))
        XCTAssertLessThan(simd_reduce_max(simd_abs(mdl.bounds.min - cube.min)), 0.001)
        XCTAssertLessThan(simd_reduce_max(simd_abs(mdl.bounds.max - cube.max)), 0.001)
        let layer = model(1, bounds: mdl.bounds, world: translation(.zero, scale: 0.01))
        let eye = SIMD3<Float>(0, 0, 3)
        for logged in [SIMD3<Float>(-21.455, -21.237, 50), SIMD3<Float>(30.841, 11.448, 50)] {
            let ray = SceneScriptCursorRay(origin: eye, direction: simd_normalize(logged * 0.01 - eye))
            let hit = SceneScriptCursorHitTest.test(layer, ray: ray, offset: .zero)
            XCTAssertTrue(hit.isInside, "\(logged)")
            XCTAssertEqual(hit.localPosition.x, logged.x, accuracy: 0.01)
            XCTAssertEqual(hit.localPosition.y, logged.y, accuracy: 0.01)
            XCTAssertEqual(hit.localPosition.z, 50, accuracy: 0.01)
        }
        let past = SceneScriptCursorRay(origin: eye, direction: simd_normalize(SIMD3<Float>(1, 1, 0) - eye))
        XCTAssertEqual(SceneScriptCursorHitTest.test(layer, ray: past, offset: .zero),
                       .init(isInside: false, localPosition: .zero))
        XCTAssertTrue(SceneScriptCursorShape.model(mdl).hitBoxes.isEmpty, "no bones, no hitBox")
    }

    func testTheModelsWorldMatrixScalesAndMovesTheBox() {
        let layer = model(1, bounds: cube, world: translation(SIMD3(0, 0, -300), scale: 2))
        XCTAssertTrue(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(99, 1), offset: .zero).isInside)
        XCTAssertTrue(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(-99, -1), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(layer, cursor: SIMD2(101, 1), offset: .zero).isInside)
        let local = SceneScriptCursorHitTest.test(layer, cursor: SIMD2(50, 50), offset: .zero).localPosition
        XCTAssertEqual(local, SIMD3(25, 25, 50), "in model units")
    }

    func testAModelWithoutMeshBoxesOrDataIsTestedAsWEDoes() {
        let unbounded = model(1, bounds: .unbounded, world: translation(.zero))
        XCTAssertTrue(SceneScriptCursorHitTest.test(unbounded, cursor: SIMD2(1000, 5), offset: .zero).isInside,
                      "±131072")
        XCTAssertTrue(SceneScriptCursorHitTest.test(unbounded, cursor: SIMD2(-1000, 5), offset: .zero).isInside)
        XCTAssertFalse(SceneScriptCursorHitTest.test(unbounded, cursor: SIMD2(-140000, 5), offset: .zero).isInside)
        let empty = model(1, bounds: MDLBounds(min: SIMD3(1, 0, 0), max: SIMD3(1, 5, 5)), world: translation(.zero))
        XCTAssertFalse(SceneScriptCursorHitTest.test(empty, cursor: SIMD2(1, 1), offset: .zero).isInside, "max.x ≤ min.x")
        XCTAssertFalse(SceneScriptCursorHitTest.test(model(1, bounds: nil, world: translation(.zero)),
                                                     cursor: .zero, offset: .zero).isInside, "no model data")
    }

    func testAPerspectiveRayRunsFromTheEyeThroughTheCursor() throws {
        let eye = SIMD3<Float>(0, 0, 1000)
        let view = SceneCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let projection = SceneCamera.perspective(fovDegrees: 50, aspect: 16 / 9, near: 1, far: 10000)
        let centre = try XCTUnwrap(SceneScriptCursorRay.perspective(eye: eye, viewProjection: projection * view,
                                                                      normalized: SIMD2(0.5, 0.5)))
        XCTAssertEqual(centre.origin, eye)
        XCTAssertEqual(centre.direction.z, -1, accuracy: 1e-5)
        let right = try XCTUnwrap(SceneScriptCursorRay.perspective(eye: eye, viewProjection: projection * view,
                                                                     normalized: SIMD2(1, 0.5)))
        // The right edge of a 50° vertical fov at 16:9.
        let halfWidth: Float = tan(25 * Float.pi / 180) * 16 / 9
        XCTAssertEqual(right.direction.x / -right.direction.z, halfWidth, accuracy: 1e-4)
        XCTAssertEqual(right.direction.y, 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(right.direction), 1, accuracy: 1e-5)
    }

    func testAQuadIsHitAlongAPerspectiveRay() {
        let quad = SceneScriptCursorLayer(slot: 1, worldMatrix: translation(.zero), size: SIMD2(100, 50))
        let ray = SceneScriptCursorRay(origin: SIMD3(0, 0, 1000), direction: simd_normalize(SIMD3(10, 0, -1000)))
        let hit = SceneScriptCursorHitTest.test(quad, ray: ray, offset: .zero)
        XCTAssertTrue(hit.isInside)
        XCTAssertEqual(hit.localPosition.x, 60, accuracy: 1e-3)
        XCTAssertEqual(hit.localPosition.y, 25, accuracy: 1e-3)
        // A quad turned edge-on to the ray (about y by 90°) is never hit.
        let turned = simd_float4x4(SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(1, 0, 0, 0), SIMD4(0, 0, 0, 1))
        let edgeOn = SceneScriptCursorLayer(slot: 1, worldMatrix: turned, size: SIMD2(100, 50))
        XCTAssertFalse(SceneScriptCursorHitTest.test(edgeOn, ray: SceneScriptCursorRay(origin: SIMD3(0, 0, 1000),
                                                                                         direction: SIMD3(0, 0, -1)),
                                                     offset: .zero).isInside)
    }

    func testAPerspectiveSceneVisitsTheNearestOriginFirst() {
        var pass = SceneScriptCursorPass()
        // Draw order bottom first: 1 is drawn above 2, but 2's origin is nearer along the view.
        var far = SceneScriptCursorLayer(slot: 1, worldMatrix: translation(.zero), size: SIMD2(100, 100), disablesPropagation: true)
        far.originZ = -500
        var near = SceneScriptCursorLayer(slot: 2, worldMatrix: translation(.zero), size: SIMD2(100, 100), disablesPropagation: true)
        near.originZ = 100
        let ray = SceneScriptCursorRay(origin: SIMD3(0, 0, 1000), direction: SIMD3(0, 0, -1))
        let frame = SceneScriptCursorFrame(cursorWorldPosition: .zero, leftButtonDown: false, ray: ray,
                                           viewForward: SIMD3(0, 0, -1), layers: [near, far])
        XCTAssertEqual(frame.visitOrder.map(\.slot), [2, 1])
        XCTAssertEqual(pass.update(frame).map(\.slot), [2, 2], "the nearer object stops the pass")
        let flat = SceneScriptCursorFrame(cursorWorldPosition: .zero, leftButtonDown: false, layers: [near, far])
        XCTAssertEqual(flat.visitOrder.map(\.slot), [1, 2], "an orthographic scene keeps the draw order, top first")
        let tied = SceneScriptCursorFrame(cursorWorldPosition: .zero, leftButtonDown: false, ray: ray,
                                          viewForward: SIMD3(1, 0, 0), layers: [near, far])
        XCTAssertEqual(tied.visitOrder.map(\.slot), [1, 2], "equal keys keep the draw order, top first")
    }

    func testAModelGetsCursorEventsWithItsLocalPosition() {
        var pass = SceneScriptCursorPass()
        let frame = SceneScriptCursorFrame(cursorWorldPosition: SIMD3(520, 490, 0), leftButtonDown: false,
                                           layers: [model(7, bounds: cube, world: translation(SIMD3(500, 500, 0)))])
        XCTAssertEqual(pass.update(frame).first, SceneScriptCursorEvent(callback: .cursorEnter, slot: 7,
                                                                        worldPosition: SIMD3(520, 490, 0),
                                                                        localPosition: SIMD3(20, -10, 50)))
    }

    func testTheTableGivesAModelItsRenderersWorldOrNoBox() throws {
        let entries = [SceneScriptCursorLayer.TableEntry(slot: 0, shape: .model(cube))]
        let context = try XCTUnwrap(JSContext())
        let table = try XCTUnwrap(SceneScriptObjectTable(capacity: 1, in: context))
        table.reset(slot: 0, with: [:])
        let drawn = SceneScriptCursorLayer.layers(in: table, drawOrder: entries, parentOf: { _ in nil },
                                                  world: { _ in self.translation(SIMD3(1, 2, 3)) })
        XCTAssertEqual(drawn.first?.shape, .model(cube))
        XCTAssertEqual(drawn.first?.worldMatrix.columns.3, SIMD4(1, 2, 3, 1))
        let undrawn = SceneScriptCursorLayer.layers(in: table, drawOrder: entries, parentOf: { _ in nil })
        XCTAssertEqual(undrawn.first?.shape, .model(nil), "a model the renderer has no world for isn't tested")
    }

    func testAModelObjectDescribesItsBoxFromItsMDL() throws {
        let describer = SceneScriptSceneDescriber(userProperties: SceneScriptUserProperties(), file: { path in
            try? Fixtures.data("Models/" + path)
        })
        let bounded = try MDLModel(contentsOf: Fixtures.url("Models/v17-bounds.mdl"))
        XCTAssertEqual(describer.modelObject("v17-bounds.mdl", animationLayers: nil).cursor, .model(bounded))
        XCTAssertEqual(describer.modelObject("v4-static.mdl", animationLayers: nil).cursor?.kind, .model(.unbounded))
        XCTAssertNil(describer.modelObject("missing.mdl", animationLayers: nil).cursor)
    }
}
