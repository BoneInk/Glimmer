import XCTest
@testable import OWESceneEditing

/// The gizmo's modes on a 2D scene (Translate, Rotate, Scale, Multi) and the 3D scene's gizmo
/// through a camera, in world and local space.
final class GizmoModeTests: XCTestCase {
    private func assertEqual(_ a: SIMD3<Double>, _ b: SIMD3<Double>, accuracy: Double = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, file: file, line: line)
    }

    /// A 200 × 100 layer at the centre of a 1000 × 500 scene drawn one point per unit.
    private func layout() -> (CanvasViewport, LayerGeometry) {
        let viewport = CanvasViewport(sceneSize: SIMD2(1000, 500), canvasSize: SIMD2(1048, 548))
        let geometry = LayerGeometry(transform: LayerTransform(origin: SIMD3(500, 250, 0)), size: SIMD2(200, 100))
        return (viewport, geometry)
    }

    // MARK: 2D

    func testTranslateArrowsMoveAlongOneAxis() {
        let (viewport, geometry) = layout()
        XCTAssertEqual(viewport.scale, 1, accuracy: 1e-12)
        let pivot = viewport.canvasPoint(geometry.pivot)
        let onX = pivot + SIMD2(50, 0), onY = pivot + SIMD2(0, -50)
        XCTAssertEqual(LayerGizmo.handle(at: onX, geometry: geometry, viewport: viewport, mode: .translate), .axis(0))
        XCTAssertEqual(LayerGizmo.handle(at: onY, geometry: geometry, viewport: viewport, mode: .translate), .axis(1))
        XCTAssertEqual(LayerGizmo.handle(at: pivot, geometry: geometry, viewport: viewport, mode: .translate), .body)
        let drag = LayerGizmo.Drag(handle: .axis(0), start: geometry, startPoint: viewport.scenePoint(onX))
        let moved = drag.transform(at: viewport.scenePoint(onX + SIMD2(30, 40)))
        XCTAssertEqual(moved.origin.x, 530, accuracy: 1e-9)
        XCTAssertEqual(moved.origin.y, 250, accuracy: 1e-9, "the arrow keeps the layer on its axis")
    }

    func testRotateRingTurnsAboutThePivot() {
        let (viewport, geometry) = layout()
        let pivot = viewport.canvasPoint(geometry.pivot)
        let onRing = pivot + SIMD2(LayerGizmo.ringRadius, 0)
        XCTAssertEqual(LayerGizmo.handle(at: onRing, geometry: geometry, viewport: viewport, mode: .rotate), .rotate)
        XCTAssertNil(LayerGizmo.handle(at: pivot + SIMD2(20, 0), geometry: geometry, viewport: viewport, mode: .rotate),
                     "inside the ring, the layer's body isn't a handle in Rotate")
        let drag = LayerGizmo.Drag(handle: .rotate, start: geometry, startPoint: viewport.scenePoint(onRing))
        // A quarter turn up the screen is a quarter turn counter-clockwise in scene space (y up).
        let turned = drag.transform(at: viewport.scenePoint(pivot + SIMD2(0, -LayerGizmo.ringRadius)))
        XCTAssertEqual(turned.angles.z, .pi / 2, accuracy: 1e-9)
    }

    func testScaleHandlesScaleTheirOwnAxisAndTheCentreBoth() {
        let (viewport, geometry) = layout()
        let pivot = viewport.canvasPoint(geometry.pivot)
        let xHandle = pivot + SIMD2(LayerGizmo.axisLength, 0)
        XCTAssertEqual(LayerGizmo.handle(at: xHandle, geometry: geometry, viewport: viewport, mode: .scale), .scaleAxis(0))
        XCTAssertEqual(LayerGizmo.handle(at: pivot, geometry: geometry, viewport: viewport, mode: .scale), .scaleUniform)
        let axisDrag = LayerGizmo.Drag(handle: .scaleAxis(0), start: geometry, startPoint: viewport.scenePoint(xHandle))
        let wider = axisDrag.transform(at: viewport.scenePoint(xHandle + SIMD2(LayerGizmo.axisLength, 25)))
        XCTAssertEqual(wider.scale.x, 2, accuracy: 1e-9)
        XCTAssertEqual(wider.scale.y, 1, accuracy: 1e-9)
        let uniform = LayerGizmo.Drag(handle: .scaleUniform, start: geometry, startPoint: viewport.scenePoint(pivot))
        let larger = uniform.transform(at: viewport.scenePoint(pivot + SIMD2(LayerGizmo.uniformScaleDistance, 0)))
        XCTAssertEqual(larger.scale.x, exp(1), accuracy: 1e-9)
        XCTAssertEqual(larger.scale.y, exp(1), accuracy: 1e-9)
    }

    func testLocalTranslateFollowsTheLayersTurn() {
        var (viewport, geometry) = layout()
        geometry.transform.angles.z = .pi / 2
        let pivot = viewport.canvasPoint(geometry.pivot)
        // Turned a quarter, the layer's own x points up the screen.
        let up = pivot + SIMD2(0, -40)
        XCTAssertEqual(LayerGizmo.handle(at: up, geometry: geometry, viewport: viewport, mode: .translate, space: .local), .axis(0))
        XCTAssertEqual(LayerGizmo.handle(at: up, geometry: geometry, viewport: viewport, mode: .translate, space: .world), .axis(1))
        let drag = LayerGizmo.Drag(handle: .axis(0), start: geometry, startPoint: viewport.scenePoint(up), space: .local)
        let moved = drag.transform(at: viewport.scenePoint(up + SIMD2(25, -30)))
        XCTAssertEqual(moved.origin.x, 500, accuracy: 1e-9)
        XCTAssertEqual(moved.origin.y, 280, accuracy: 1e-9)
    }

    func testModesAndSpacesAsWEsToolbarHasThem() {
        XCTAssertEqual(GizmoMode.offered(spatial: false), [.multi, .translate, .rotate, .scale])
        XCTAssertEqual(GizmoMode.offered(spatial: true), [.translate, .rotate, .scale], "Multi is 2D only")
        XCTAssertEqual(GizmoMode.initial(spatial: false), .multi)
        XCTAssertEqual(GizmoMode.initial(spatial: true), .translate)
        XCTAssertEqual(GizmoMode.translate.defaultSpace, .world)
        XCTAssertEqual(GizmoMode.rotate.defaultSpace, .local)
        XCTAssertEqual(GizmoMode.allCases.filter(\.hasSpaceChoice), [.translate, .rotate])
        let (viewport, geometry) = layout()
        XCTAssertEqual(LayerGizmo.handle(at: viewport.canvasPoint(geometry.corners[2]), geometry: geometry, viewport: viewport,
                                         mode: .none), .body, "none has no handles: a corner is the body's edge")
    }

    func testMultiKeepsTheCombinedHandles() {
        let (viewport, geometry) = layout()
        let corner = viewport.canvasPoint(geometry.corners[2])
        XCTAssertEqual(LayerGizmo.handle(at: corner, geometry: geometry, viewport: viewport), .corner(2))
        XCTAssertEqual(LayerGizmo.handle(at: LayerGizmo.rotateHandle(geometry, in: viewport), geometry: geometry,
                                         viewport: viewport, mode: .multi), .rotate)
        XCTAssertEqual(LayerGizmo.handle(at: viewport.canvasPoint(SIMD2(450, 260)), geometry: geometry, viewport: viewport), .body)
    }

    // MARK: Matrices

    func testWELocalMatrixAndAnglesRoundTrip() throws {
        let angles = SIMD3<Double>(0.3, -0.4, 1.1)
        let (row0, row1, row2) = EditorMatrix4.rotationRows(angles)
        assertEqual(EditorMatrix4.angles(row0: row0, row1: row1, row2: row2), angles)
        let transform = LayerTransform(origin: SIMD3(1, 2, 3), scale: SIMD3(2, 3, 4), angles: angles)
        let local = EditorMatrix4.local(transform)
        assertEqual(local.applyPoint(.zero), SIMD3(1, 2, 3))
        assertEqual(local.axis(0), row0 * 2)
        let inverse = try XCTUnwrap(local.inverted)
        assertEqual(inverse.applyPoint(local.applyPoint(SIMD3(5, -6, 7))), SIMD3(5, -6, 7))
        // A quarter turn about z sends x to y, as WE's Rz does.
        assertEqual(EditorMatrix4.local(LayerTransform(angles: SIMD3(0, 0, .pi / 2))).applyVector(SIMD3(1, 0, 0)), SIMD3(0, 1, 0))
        assertEqual(EditorMatrix4.rotation(about: SIMD3(0, 0, 1), angle: .pi / 2).applyVector(SIMD3(1, 0, 0)), SIMD3(0, 1, 0))
    }

    // MARK: 3D

    /// A camera at z = 10 looking down −z with a 90° vertical fov over a 16:9 target.
    private func camera() -> EditorSceneCamera {
        let view = EditorMatrix4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, -10, 1)))
        let aspect = 16.0 / 9.0, near = 0.1, far = 100.0, f = 1 / tan(Double.pi / 4)
        let projection = EditorMatrix4(columns: (SIMD4(f / aspect, 0, 0, 0), SIMD4(0, f, 0, 0),
                                                 SIMD4(0, 0, far / (near - far), -1), SIMD4(0, 0, near * far / (near - far), 0)))
        return EditorSceneCamera(view: view, projection: projection)
    }

    private func viewport3D() -> CanvasViewport {
        CanvasViewport(sceneSize: SIMD2(1920, 1080), canvasSize: SIMD2(1008, 588))
    }

    func testTheCameraPutsTheOriginAtTheCanvasCentre() throws {
        let viewport = viewport3D()
        let centre = try XCTUnwrap(camera().canvasPoint(.zero, in: viewport))
        XCTAssertEqual(centre.x, 504, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 294, accuracy: 1e-9)
        XCTAssertNil(camera().canvasPoint(SIMD3(0, 0, 20), in: viewport), "behind the camera")
        let back = try XCTUnwrap(camera().worldPoint(at: centre + SIMD2(30, 0), depthOf: .zero, in: viewport))
        XCTAssertEqual(back.z, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(back.x, 0)
    }

    func testArrowsMoveAlongTheirAxisInWorldUnits() throws {
        let viewport = viewport3D(), camera = camera()
        let spatial = LayerSpatial(transform: LayerTransform(origin: .zero))
        let frame = try XCTUnwrap(Gizmo3D.frame(spatial, space: .world, camera: camera, viewport: viewport))
        let tip = try XCTUnwrap(frame.tip(0))
        XCTAssertEqual(Gizmo3D.handle(at: (frame.pivot + tip) / 2, frame: frame, mode: .translate), .move(0))
        XCTAssertNil(frame.direction(2), "z points at the camera")
        // At this depth one world unit is 27 points (half the 540-point height over tan 45° × 10).
        XCTAssertEqual(frame.screenAxes[0].x, 27, accuracy: 1e-3)
        let drag = Gizmo3D.Drag(handle: .move(0), start: spatial, frame: frame, startPoint: tip)
        let moved = drag.transform(at: tip + SIMD2(54, 30), camera: camera, viewport: viewport)
        assertEqual(moved.origin, SIMD3(2, 0, 0), accuracy: 1e-3)
    }

    func testRingsTurnAboutTheWorldOrTheObjectsAxis() throws {
        let viewport = viewport3D(), camera = camera()
        // Turned a quarter about y: its own x points along world −z.
        let spatial = LayerSpatial(transform: LayerTransform(angles: SIMD3(0, .pi / 2, 0)))
        let world = try XCTUnwrap(Gizmo3D.frame(spatial, space: .world, camera: camera, viewport: viewport))
        XCTAssertEqual(world.ringSense[2], 1, "z faces the camera: a positive turn about it is counter-clockwise")
        let start = world.pivot + SIMD2(Gizmo3D.ringRadius, 0)
        let drag = Gizmo3D.Drag(handle: .rotate(2), start: spatial, frame: world, startPoint: start)
        let turned = drag.transform(at: world.pivot + SIMD2(0, -Gizmo3D.ringRadius), camera: camera, viewport: viewport)
        let (row0, _, _) = EditorMatrix4.rotationRows(turned.angles)
        // World z turns world −z… its own x stays along −z; its own y (world y) turns to −x.
        assertEqual(row0, SIMD3(0, 0, -1), accuracy: 1e-6)
        let (_, row1, _) = EditorMatrix4.rotationRows(turned.angles)
        assertEqual(row1, SIMD3(-1, 0, 0), accuracy: 1e-6)

        let local = try XCTUnwrap(Gizmo3D.frame(spatial, space: .local, camera: camera, viewport: viewport))
        let localDrag = Gizmo3D.Drag(handle: .rotate(0), start: spatial, frame: local, startPoint: start)
        let aboutOwnX = localDrag.transform(at: world.pivot + SIMD2(0, -Gizmo3D.ringRadius), camera: camera, viewport: viewport)
        let (ownX, _, _) = EditorMatrix4.rotationRows(aboutOwnX.angles)
        assertEqual(ownX, SIMD3(0, 0, -1), accuracy: 1e-6) // turning about its own x keeps x
    }

    func testScaleAlongTheObjectsOwnAxisAndUniformly() throws {
        let viewport = viewport3D(), camera = camera()
        let spatial = LayerSpatial(transform: LayerTransform(scale: SIMD3(1, 2, 1)))
        let frame = try XCTUnwrap(Gizmo3D.frame(spatial, space: .world, camera: camera, viewport: viewport))
        let tip = try XCTUnwrap(frame.tip(1, own: true))
        XCTAssertEqual(Gizmo3D.handle(at: tip, frame: frame, mode: .scale), .scale(1))
        let drag = Gizmo3D.Drag(handle: .scale(1), start: spatial, frame: frame, startPoint: tip)
        let taller = drag.transform(at: tip + SIMD2(0, -Gizmo3D.axisLength), camera: camera, viewport: viewport)
        assertEqual(taller.scale, SIMD3(1, 4, 1))
        XCTAssertEqual(Gizmo3D.handle(at: frame.pivot, frame: frame, mode: .scale), .scaleUniform)
        XCTAssertEqual(Gizmo3D.handle(at: frame.pivot, frame: frame, mode: .multi), .moveFree)
    }

    func testAChildMovesInItsParentsSpace() throws {
        let viewport = viewport3D(), camera = camera()
        // The parent is scaled by 2: a world move of 2 is a local move of 1.
        let parent = EditorMatrix4.local(LayerTransform(scale: SIMD3(2, 2, 2)))
        let spatial = LayerSpatial(transform: LayerTransform(origin: .zero), parent: parent)
        let frame = try XCTUnwrap(Gizmo3D.frame(spatial, space: .world, camera: camera, viewport: viewport))
        let tip = try XCTUnwrap(frame.tip(0))
        let drag = Gizmo3D.Drag(handle: .move(0), start: spatial, frame: frame, startPoint: tip)
        let moved = drag.transform(at: tip + SIMD2(54, 0), camera: camera, viewport: viewport)
        assertEqual(moved.origin, SIMD3(1, 0, 0), accuracy: 1e-3)
    }

    @MainActor
    func testPickingAnObjectOfA3DSceneByItsOrigin() throws {
        let scene = Data(#"""
        {"camera": {"center": "0 0 0", "eye": "0 0 10", "up": "0 1 0"},
         "general": {"fov": 90},
         "objects": [{"id": 1, "name": "Box", "model": "models/box.json", "origin": "1 0 0"},
                     {"id": 2, "name": "Lamp", "light": "point", "origin": "-1 0 0", "parent": 1},
                     {"id": 3, "name": "Music", "sound": ["sounds/a.mp3"]}]}
        """#.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene))
        XCTAssertNil(session.outline.size)
        XCTAssertNil(session.spatial(of: 3), "a sound has no place")
        let lamp = try XCTUnwrap(session.spatial(of: 2))
        assertEqual(lamp.pivot, .zero, accuracy: 1e-9)
        let viewport = viewport3D(), camera = camera()
        let box = try XCTUnwrap(camera.canvasPoint(SIMD3(1, 0, 0), in: viewport))
        XCTAssertEqual(session.spatialLayer(at: box + SIMD2(3, 2), camera: camera, viewport: viewport), 1)
        XCTAssertEqual(session.spatialLayer(at: try XCTUnwrap(camera.canvasPoint(.zero, in: viewport)), camera: camera,
                                            viewport: viewport), 2)
        XCTAssertNil(session.spatialLayer(at: box + SIMD2(60, 0), camera: camera, viewport: viewport))
    }
}
