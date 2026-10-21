import XCTest
@testable import OWESceneEditing

/// Effect gizmos: `effect.json`'s `gizmos` read with their conditions, laid out on the layer, and
/// dragged into the effect's constants as one undo step; `"position": true` and
/// `"direction": true` constants get their own controls.
@MainActor
final class EffectGizmoTests: XCTestCase {
    private func assertEqual(_ a: [Double]?, _ b: [Double], accuracy: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        guard let a, a.count == b.count else { return XCTFail("\(String(describing: a)) is not \(b)", file: file, line: line) }
        for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
    }

    /// Advanced Fluid Simulation's shape: point emitters shown from a combo value on, and WE's
    /// trailing commas.
    private static let fluidJSON = Data(#"""
    {"version": 1, "passes": [{"material": "materials/effects/fluid.json"}],
     "gizmos": [
       {"type": "EffectPointEmitter", "condition": {"POINTEMITTER": {"op": "ge", "value": 1}},
        "vars": {"center": "emitterPos0", "angle": "emitterAngle0", "size": "emitterSize0", "speed": "emitterSpeed0"}},
       {"type": "EffectPointEmitter", "condition": {"POINTEMITTER": {"op": "ge", "value": 2}},
        "vars": {"center": "emitterPos1", "angle": "emitterAngle1", "size": "emitterSize1", "speed": "emitterSpeed1"}},
       {"type": "EffectPerspectiveUV", "condition": {"PERSPECTIVE": 1},
        "vars": {"p0": "point0", "p1": "point1", "p2": "point2", "p3": "point3"}},
       {"type": "SomethingNew", "vars": {}},
     ]}
    """#.utf8)

    func testGizmosAreReadWithTheirConditions() throws {
        let gizmos = try EffectGizmo.gizmos(effectJSON: Self.fluidJSON)
        XCTAssertEqual(gizmos.map(\.kind), [.pointEmitter, .pointEmitter, .perspectiveUV], "an unknown type is left out")
        XCTAssertEqual(gizmos[0].key("center"), "emitterPos0")
        XCTAssertEqual(gizmos[1].conditions, [EffectGizmo.Condition(combo: "POINTEMITTER", op: "ge", value: 2)])
        XCTAssertEqual(gizmos[2].conditions, [EffectGizmo.Condition(combo: "PERSPECTIVE", value: 1)])
        XCTAssertTrue(gizmos[1].shows { $0 == "POINTEMITTER" ? 3 : 0 })
        XCTAssertFalse(gizmos[1].shows { $0 == "POINTEMITTER" ? 1 : 0 })
        XCTAssertFalse(gizmos[2].shows { _ in 0 })
        XCTAssertEqual(try EffectGizmo.gizmos(effectJSON: Data(#"{"passes": []}"#.utf8)), [])
    }

    func testPositionAndDirectionConstantsHaveTheirControls() {
        let position = EffectSchema.Parameter(key: "center", title: "Center", defaultValue: [0.5, 0.5], isPosition: true)
        let direction = EffectSchema.Parameter(key: "direction", title: "Direction", defaultValue: [0], isDirection: true,
                                               showsDegrees: true)
        XCTAssertEqual(position.control, .position)
        XCTAssertEqual(direction.control, .direction)
        XCTAssertEqual(EffectSchema.Parameter(key: "speed", title: "Speed", defaultValue: [1], isDirection: true).control,
                       .direction)
        XCTAssertEqual(EffectSchema.Parameter(key: "size", title: "Size", defaultValue: [1, 1], isDirection: true).control,
                       .vector(2), "a direction is one angle")
    }

    // MARK: Layout

    /// A 400 × 200 layer centred in a 1000 × 500 scene drawn one point per unit, its top-left
    /// corner at canvas (324, 174).
    private func mapping() -> EffectGizmoLayout.Mapping {
        let viewport = CanvasViewport(sceneSize: SIMD2(1000, 500), canvasSize: SIMD2(1048, 548))
        let geometry = LayerGeometry(transform: LayerTransform(origin: SIMD3(500, 250, 0)), size: SIMD2(400, 200))
        return EffectGizmoLayout.Mapping(geometry: geometry, viewport: viewport)
    }

    func testUVMapsToTheLayersRectangleTopLeftFirst() throws {
        let mapping = mapping()
        XCTAssertEqual(mapping.toCanvas(SIMD2(0, 0)), SIMD2(324, 174))
        XCTAssertEqual(mapping.toCanvas(SIMD2(1, 1)), SIMD2(724, 374))
        let back = try XCTUnwrap(mapping.toUV(SIMD2(424, 324)))
        assertEqual([back.x, back.y], [0.25, 0.75])
        XCTAssertEqual(mapping.aspect, 2)
    }

    func testPerspectiveCornersAndAPositionPointFollowThePointer() {
        let mapping = mapping()
        let perspective = EffectGizmoLayout(kind: .perspectiveUV, values: [:])
        XCTAssertEqual(perspective.handles(mapping).map(\.role), ["p0", "p1", "p2", "p3"])
        XCTAssertEqual(perspective.handles(mapping)[2].point, SIMD2(724, 374), "p2 defaults to the bottom-right corner")
        assertEqual(perspective.dragged("p1", to: SIMD2(624, 224), mapping)["p1"], [0.75, 0.25])
        let point = EffectGizmoLayout(kind: nil, values: ["position": [0.5, 0.5]])
        XCTAssertEqual(point.handles(mapping).first?.point, SIMD2(524, 274))
        assertEqual(point.dragged("position", to: SIMD2(324, 374), mapping)["position"], [0, 1])
    }

    func testSpinsEllipseHandlesSetItsSizeRatioAndAngle() throws {
        let mapping = mapping()
        let spin = EffectGizmoLayout(kind: .spinUV, values: ["center": [0.5, 0.5], "size": [0.2], "ratio": [2], "angle": [0.5]],
                                     ranges: ["size": 0...1, "ratio": 0...10, "angle": 0...3.141])
        let handles = Dictionary(uniqueKeysWithValues: spin.handles(mapping).map { ($0.role, $0.point) })
        // Dragging a handle to where it already is gives the values back.
        assertEqual(spin.dragged("size", to: try XCTUnwrap(handles["size"]), mapping)["size"], [0.2])
        let ratio = spin.dragged("ratio", to: try XCTUnwrap(handles["ratio"]), mapping)
        assertEqual(ratio["ratio"], [2])
        assertEqual(ratio["angle"], [0.5])
        // In aspect space the size handle is `size` from the centre: 0.2 of the layer's height.
        let size = try XCTUnwrap(handles["size"]) - SIMD2(524, 274)
        XCTAssertEqual((size * size).sum().squareRoot(), 40, accuracy: 1e-6)
        assertEqual(spin.dragged("size", to: SIMD2(524, 374), mapping)["size"], [0.5])
    }

    func testSwingsCentreSlidesAlongItsHingeAndItsPageSizeAcrossIt() {
        let mapping = mapping()
        let swing = EffectGizmoLayout(kind: .swingUV, values: ["p0": [0.25, 0.5], "p1": [0.75, 0.5], "center": [0.5], "size": [0.4]],
                                      ranges: ["center": 0...1, "size": 0...1])
        let handles = Dictionary(uniqueKeysWithValues: swing.handles(mapping).map { ($0.role, $0.point) })
        XCTAssertEqual(handles["center"], SIMD2(524, 274))
        // The page hangs below the hinge: 0.4 of the layer's height.
        XCTAssertEqual(handles["size"]?.y ?? 0, 354, accuracy: 1e-9)
        assertEqual(swing.dragged("center", to: SIMD2(474, 300), mapping)["center"], [0.25])
        assertEqual(swing.dragged("size", to: SIMD2(600, 294), mapping)["size"], [0.1])
        assertEqual(swing.dragged("size", to: SIMD2(600, 200), mapping)["size"], [0]) // never above the hinge
    }

    func testEmittersPointUpAtZeroAndTurnClockwise() throws {
        let mapping = mapping()
        let emitter = EffectGizmoLayout(kind: .pointEmitter, values: ["center": [0.5, 0.5], "size": [0.1], "angle": [0]])
        let handles = Dictionary(uniqueKeysWithValues: emitter.handles(mapping).map { ($0.role, $0.point) })
        let arrow = try XCTUnwrap(handles["angle"])
        XCTAssertEqual(arrow.x, 524, accuracy: 1e-6)
        XCTAssertLessThan(arrow.y, 274, "0 points up")
        assertEqual(emitter.dragged("angle", to: SIMD2(600, 274), mapping)["angle"], [.pi / 2])
        assertEqual(emitter.dragged("angle", to: SIMD2(400, 274), mapping)["angle"], [3 * .pi / 2])
        assertEqual(emitter.dragged("size", to: SIMD2(604, 274), mapping)["size"], [0.2], accuracy: 1e-9)
        let line = EffectGizmoLayout(kind: .lineEmitter, values: ["p0": [0.25, 0.5], "p1": [0.75, 0.5], "size": [0.05], "angle": [.pi]])
        XCTAssertEqual(line.handles(mapping).map(\.role), ["p0", "p1", "size", "angle"])
        assertEqual(line.dragged("size", to: SIMD2(524, 254), mapping)["size"], [0.1])
    }

    // MARK: Session

    private func session() throws -> SceneEditSession {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    private static let schema = EffectSchema(
        parameters: [EffectSchema.Parameter(key: "emitterPos0", title: "Position", defaultValue: [0.5, 0.5], isPosition: true),
                     EffectSchema.Parameter(key: "emitterSize0", title: "Size", defaultValue: [0.05], maximum: 0.3),
                     EffectSchema.Parameter(key: "emitterAngle0", title: "Angle", defaultValue: [0], isDirection: true),
                     EffectSchema.Parameter(key: "Center", title: "Center", defaultValue: [0.5, 0.5], isPosition: true)],
        combos: [EffectSchema.Combo(name: "POINTEMITTER", title: "Point Emitters", defaultValue: 1)],
        gizmos: [EffectGizmo(kind: .pointEmitter, vars: ["center": "emitterPos0", "size": "emitterSize0", "angle": "emitterAngle0"],
                             conditions: [EffectGizmo.Condition(combo: "POINTEMITTER", op: "ge", value: 1)])])

    func testALayersEffectGizmosFollowItsCombosAndValues() throws {
        let session = try session()
        let effect = try XCTUnwrap(session.outline.layer(10)?.effects.first)
        var gizmos = session.effectGizmos(effect, of: 10, schema: Self.schema)
        XCTAssertEqual(gizmos.map(\.layout.kind), [.pointEmitter, nil], "the emitter, and the position constant no gizmo sets")
        XCTAssertEqual(gizmos[1].keys, ["position": "Center"])
        XCTAssertEqual(gizmos[0].layout.ranges["size"], 0...0.3)
        XCTAssertNil(gizmos[0].layout.ranges["angle"], "a direction turns all the way")
        session.setEffectCombo("POINTEMITTER", to: 0, effect: effect.key, of: 10, defaultValue: 1, actionName: "Off")
        gizmos = session.effectGizmos(effect, of: 10, schema: Self.schema)
        XCTAssertEqual(gizmos.map(\.layout.kind), [nil])
    }

    func testDraggingSetsTheConstantsAsOneUndoStep() throws {
        let session = try session()
        let effect = try XCTUnwrap(session.outline.layer(10)?.effects.first)
        session.setEffectConstants(["emitterPos0": [0.2, 0.3], "emitterAngle0": [1]], effect: effect.key, of: 10,
                                   schema: Self.schema, actionName: "Move", coalescingKey: "drag")
        session.setEffectConstants(["emitterPos0": [0.25, 0.35]], effect: effect.key, of: 10,
                                   schema: Self.schema, actionName: "Move", coalescingKey: "drag")
        XCTAssertEqual(session.effectConstantComponents("emitterPos0", effect: effect.key, of: 10, default: [0.5, 0.5]), [0.25, 0.35])
        XCTAssertEqual(session.effectConstant("emitterAngle0", effect: effect.key, of: 10), .number(1))
        XCTAssertEqual(session.effectGizmos(effect, of: 10, schema: Self.schema).first?.layout.values["center"], [0.25, 0.35])
        session.undo()
        XCTAssertNil(session.effectConstant("emitterPos0", effect: effect.key, of: 10), "the drag was one step")
        XCTAssertNil(session.effectConstant("emitterAngle0", effect: effect.key, of: 10))
        // The shader's default is no edit.
        session.setEffectConstants(["emitterSize0": [0.05]], effect: effect.key, of: 10, schema: Self.schema, actionName: "Size")
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }
}
