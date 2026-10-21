import XCTest
import simd
@testable import OpenWallpaperEngine

private struct PropertyContext: SceneValueContext {
    var properties: [String: String] = [:]
    func userProperty(_ name: String) -> String? { properties[name] }
}

/// A fixed-seed generator, so a failing random case reproduces.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// docs/models-plan.md M3: WE's object matrices (0x1401dd630's rows, 0x1401850a0's local and
/// world), the 3D hierarchy with its attachment hook, and the live 3D values.
final class SceneTransform3DTests: XCTestCase {
    private func assertEqual(_ a: SIMD3<Float>, _ b: SIMD3<Float>, accuracy: Float = 1e-5, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(simd_length(a - b), accuracy, "\(a) vs \(b): \(message)", file: file, line: line)
    }

    private func assertEqual(_ a: simd_float4x4, _ b: simd_float4x4, accuracy: Float = 1e-4, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        for column in 0..<4 {
            XCTAssertLessThanOrEqual(simd_length(a[column] - b[column]), accuracy,
                                     "column \(column): \(a[column]) vs \(b[column]): \(message)", file: file, line: line)
        }
    }

    private func randomAngles(_ generator: inout SplitMix64) -> SIMD3<Float> {
        SIMD3(Float.random(in: -.pi ... .pi, using: &generator), Float.random(in: -.pi ... .pi, using: &generator),
              Float.random(in: -.pi ... .pi, using: &generator))
    }

    private func objects(_ json: String) throws -> [WESceneObject] {
        try JSONDecoder().decode([WESceneObject].self, from: Data(json.utf8))
    }

    // MARK: - Rows

    /// 0x1401dd630's rows, written out from its multiplies, for random angles; and the same as
    /// the basis vectors of `Rz·Ry·Rx` built from the three axis rotations (row i = R's column i).
    func testRowsMatchWEsFormulaForRandomAngles() {
        var generator = SplitMix64(state: 0x1401dd630)
        for _ in 0..<500 {
            let a = randomAngles(&generator)
            let (row0, row1, row2) = SceneWorldMatrix.rows(a)
            let cx = cos(a.x), sx = sin(a.x), cy = cos(a.y), sy = sin(a.y), cz = cos(a.z), sz = sin(a.z)
            assertEqual(row0, SIMD3(cy * cz, cy * sz, -sy), "row0 at \(a)")
            assertEqual(row1, SIMD3(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy), "row1 at \(a)")
            assertEqual(row2, SIMD3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy), "row2 at \(a)")

            let rx = simd_float3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, cx, sx), SIMD3(0, -sx, cx)))
            let ry = simd_float3x3(columns: (SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy)))
            let rz = simd_float3x3(columns: (SIMD3(cz, sz, 0), SIMD3(-sz, cz, 0), SIMD3(0, 0, 1)))
            let r = rz * ry * rx
            assertEqual(row0, r.columns.0, "R·x at \(a)")
            assertEqual(row1, r.columns.1, "R·y at \(a)")
            assertEqual(row2, r.columns.2, "R·z at \(a)")
        }
    }

    /// 0x1401850a0's local matrix: rows scaled per axis, the origin in row 3; memory is WE's.
    func testLocalMatrixScalesEachRowAndPutsTheOriginLast() {
        let local = SceneLocalTransform3D(origin: SIMD3(10, -20, 30), scale: SIMD3(2, 3, 4), angles: SIMD3(0.3, -0.7, 1.1))
        let (row0, row1, row2) = SceneWorldMatrix.rows(local.angles)
        let m = local.matrix
        assertEqual(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z), row0 * 2)
        assertEqual(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z), row1 * 3)
        assertEqual(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z), row2 * 4)
        XCTAssertEqual(m.columns.3, SIMD4(10, -20, 30, 1))
        XCTAssertEqual([m.columns.0.w, m.columns.1.w, m.columns.2.w], [0, 0, 0])
        // A point p maps to origin + Σ p_i·scale_i·row_i, WE's row-vector p·M.
        let p = SIMD3<Float>(1.5, -2, 0.25)
        let mapped = m * SIMD4(p, 1)
        assertEqual(SIMD3(mapped.x, mapped.y, mapped.z),
                    local.origin + p.x * 2 * row0 + p.y * 3 * row1 + p.z * 4 * row2)
        // Row-major bytes of WE's matrix: row0 (4 floats), row1, row2, origin.
        let bytes = withUnsafeBytes(of: m) { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(Array(bytes[12..<15]), [10, -20, 30])
        XCTAssertEqual(bytes[0], row0.x * 2, accuracy: 1e-6)
        XCTAssertEqual(bytes[2], row0.z * 2, accuracy: 1e-6)
    }

    /// Missing fields take WE's defaults (origin 0, scale 1, angles 0), a root's origin included
    /// (§5.13); `origin.z` and `scale.z` are kept, and a missing component of an authored vector is
    /// 0 (§5.14).
    func testAuthoredTransformKeepsDepthAndWEsDefaults() throws {
        let objects = try objects("""
        [{"id": 1, "origin": "1 2 3", "scale": "4 5 6", "angles": "0.1 0.2 0.3"},
         {"id": 2},
         {"id": 3, "parent": 1, "scale": "2 2"}]
        """)
        let full = SceneLocalTransform3D(object: objects[0])
        XCTAssertEqual(full, SceneLocalTransform3D(origin: SIMD3(1, 2, 3), scale: SIMD3(4, 5, 6), angles: SIMD3(0.1, 0.2, 0.3)))
        XCTAssertEqual(SceneLocalTransform3D(object: objects[1]), .identity, "a root without an origin sits at 0")
        let child = SceneLocalTransform3D(object: objects[2])
        XCTAssertEqual(child.origin, .zero, "a child without an origin sits on its parent")
        XCTAssertEqual(child.scale, SIMD3(2, 2, 0), "a missing component is 0")
        XCTAssertEqual(full.planar, SceneLocalTransform(origin: SIMD2(1, 2), scale: SIMD2(4, 5), angle: 0.3,
                                                        tilt: SIMD2(0.1, 0.2)))
    }

    // MARK: - Angles back from a basis

    /// 0x1401f31f7's extraction inverts the rows for |y| < π/2, and a look-at's forward is −row2.
    func testAnglesFromRowsInvertTheRows() {
        var generator = SplitMix64(state: 0x1401f31f7)
        for _ in 0..<500 {
            var a = randomAngles(&generator)
            a.y = Float.random(in: -1.5 ... 1.5, using: &generator)
            let (row0, row1, row2) = SceneWorldMatrix.rows(a)
            assertEqual(SceneWorldMatrix.angles(row0: row0, row1: row1, row2: row2), a, accuracy: 1e-4, "at \(a)")
        }
    }

    func testLookAtAnglesLookFromTheEyeToTheCentre() {
        var generator = SplitMix64(state: 0x14019d920)
        for _ in 0..<200 {
            let eye = SIMD3<Float>(Float.random(in: -10...10, using: &generator), Float.random(in: -10...10, using: &generator),
                                   Float.random(in: -10...10, using: &generator))
            let center = eye + simd_normalize(SIMD3(Float.random(in: -1...1, using: &generator),
                                                    Float.random(in: -0.9...0.9, using: &generator),
                                                    Float.random(in: -1...1, using: &generator))) * 5
            let angles = SceneWorldMatrix.lookAtAngles(eye: eye, center: center, up: SIMD3(0, 1, 0))
            let world = SceneLocalTransform3D(origin: eye, scale: SIMD3(repeating: 1), angles: angles).matrix
            assertEqual(SceneWorldMatrix.forward(world), simd_normalize(center - eye), accuracy: 1e-4)
            XCTAssertGreaterThan(SceneWorldMatrix.up(world).y, 0, "up stays on +Y's side")
            XCTAssertEqual(simd_dot(SceneWorldMatrix.up(world), SceneWorldMatrix.forward(world)), 0, accuracy: 1e-4)
        }
    }

    /// The forward of the camera-sync script of 3734636606 (`R·(0, 0, −1)` with angles in degrees
    /// turned to radians, R = Rz·Ry·Rx, transcribed from its `syncCameraToLayer`) is −row2, and its
    /// up is row1. `SceneTransform3DLibraryTests` runs the script itself.
    func testCameraSyncScriptsForwardIsMinusRow2() {
        var generator = SplitMix64(state: 3_734_636_606)
        for _ in 0..<500 {
            let degrees = randomAngles(&generator) * 180 / .pi
            let r = degrees * .pi / 180
            let cx = cos(r.x), sx = sin(r.x), cy = cos(r.y), sy = sin(r.y), cz = cos(r.z), sz = sin(r.z)
            let scriptForward = SIMD3(-(cz * sy * cx + sz * sx), -(sz * sy * cx - cz * sx), -(cy * cx))
            let scriptUp = SIMD3(cz * sy * sx - sz * cx, sz * sy * sx + cz * cx, cy * sx)
            let world = SceneLocalTransform3D(origin: .zero, scale: SIMD3(repeating: 1), angles: r).matrix
            let (_, row1, row2) = SceneWorldMatrix.rows(r)
            assertEqual(scriptForward, -row2)
            assertEqual(scriptUp, row1)
            assertEqual(SceneWorldMatrix.forward(world), scriptForward, accuracy: 1e-4)
        }
    }

    // MARK: - Hierarchy

    /// world = parentWorld · local, root first, over a three-level chain; each level's scale,
    /// angles and depth reach the leaf.
    func testParentChainsComposeRootFirst() {
        let root = SceneLocalTransform3D(origin: SIMD3(100, 50, -20), scale: SIMD3(2, 2, 2), angles: SIMD3(0.4, 0, 0))
        let mid = SceneLocalTransform3D(origin: SIMD3(0, 10, 5), scale: SIMD3(1, 0.5, 3), angles: SIMD3(0, 0.9, 0))
        let leaf = SceneLocalTransform3D(origin: SIMD3(3, 0, 0), scale: SIMD3(repeating: 1), angles: SIMD3(0, 0, 1.2))
        let hierarchy = SceneTransformHierarchy3D(nodes: [
            "1": .init(parentID: nil, local: root), "2": .init(parentID: "1", local: mid),
            "3": .init(parentID: "2", local: leaf),
        ])
        assertEqual(hierarchy.world(of: "3"), root.matrix * mid.matrix * leaf.matrix)
        assertEqual(hierarchy.parentWorld(of: "3"), root.matrix * mid.matrix)
        XCTAssertEqual(hierarchy.ancestors(of: "3"), ["2", "1"])
        // The leaf's origin, walked by hand through its parents' rows.
        let (m0, m1, m2) = SceneWorldMatrix.rows(mid.angles)
        let inMid = mid.origin + leaf.origin.x * mid.scale.x * m0 + leaf.origin.y * mid.scale.y * m1
            + leaf.origin.z * mid.scale.z * m2
        let (r0, r1, r2) = SceneWorldMatrix.rows(root.angles)
        let inRoot = root.origin + inMid.x * root.scale.x * r0 + inMid.y * root.scale.y * r1 + inMid.z * root.scale.z * r2
        assertEqual(SceneWorldMatrix.translation(hierarchy.world(of: "3")), inRoot, accuracy: 1e-3)
        let worlds = hierarchy.worlds()
        XCTAssertEqual(Set(worlds.keys), ["1", "2", "3"])
        assertEqual(worlds["3"]!, hierarchy.world(of: "3"))
    }

    /// A live (scripted, animated) parent moves its children; a missing parent makes a root; a
    /// cycle ends the walk.
    func testLiveParentsMissingParentsAndCycles() {
        let one = SceneLocalTransform3D(origin: SIMD3(1, 0, 0), scale: SIMD3(repeating: 1), angles: .zero)
        let hierarchy = SceneTransformHierarchy3D(nodes: [
            "1": .init(parentID: nil, local: one), "2": .init(parentID: "1", local: one),
            "3": .init(parentID: "404", local: one),
            "4": .init(parentID: "5", local: one), "5": .init(parentID: "4", local: one),
        ])
        let moved = SceneLocalTransform3D(origin: SIMD3(0, 0, 7), scale: SIMD3(repeating: 2), angles: .zero)
        XCTAssertEqual(SceneWorldMatrix.translation(hierarchy.world(of: "2") { $0 == "1" ? moved : nil }), SIMD3(2, 0, 7))
        XCTAssertEqual(SceneWorldMatrix.translation(hierarchy.world(of: "3")), SIMD3(1, 0, 0))
        XCTAssertEqual(SceneWorldMatrix.translation(hierarchy.world(of: "4")), SIMD3(2, 0, 0))
        XCTAssertEqual(hierarchy.world(of: "unknown"), matrix_identity_float4x4)
    }

    /// Built from scene objects: ids as keys (the index when an object has none), parents, and a
    /// model's `attachment`.
    func testHierarchyFromSceneObjects() throws {
        let hierarchy = SceneTransformHierarchy3D(objects: try objects("""
        [{"id": 7, "model": "models/a.mdl", "origin": "0 1 2"},
         {"id": 8, "model": "models/b.mdl", "parent": 7, "attachment": "hand", "origin": "0 0 1"},
         {"image": "models/c.json", "parent": 8}]
        """))
        XCTAssertEqual(hierarchy.nodes["7"]?.local.origin, SIMD3(0, 1, 2))
        XCTAssertEqual(hierarchy.nodes["8"]?.attachment, "hand")
        XCTAssertEqual(hierarchy.nodes["2"]?.parentID, "8")
        XCTAssertEqual(SceneWorldMatrix.translation(hierarchy.world(of: "2")), SIMD3(0, 1, 3))
    }

    /// The attachment hook (M6's): world = parentWorld · attachment · local; nil hangs the
    /// object from its parent as WE's index −1 does.
    func testAttachmentHookSitsBetweenParentAndLocal() {
        final class Hand: SceneAttachmentProviding {
            var matrix: simd_float4x4?
            var asked: [SceneAttachedObject] = []
            func attachmentWorld(_ object: SceneAttachedObject) -> simd_float4x4? {
                asked.append(object)
                return matrix
            }
        }
        let parent = SceneLocalTransform3D(origin: SIMD3(10, 0, 0), scale: SIMD3(repeating: 2), angles: SIMD3(0, 0, 0.5))
        let child = SceneLocalTransform3D(origin: SIMD3(0, 1, 0), scale: SIMD3(repeating: 1), angles: SIMD3(0.2, 0, 0))
        let hierarchy = SceneTransformHierarchy3D(nodes: [
            "1": .init(parentID: nil, local: parent, attachment: "ignored: no parent"),
            "2": .init(parentID: "1", local: child, attachment: "правая рука"),
            "3": .init(parentID: "2", local: .identity),
        ])
        let hand = Hand()
        let bone = SceneLocalTransform3D(origin: SIMD3(0, 5, 0), scale: SIMD3(repeating: 1), angles: SIMD3(0, 0.3, 0)).matrix
        hand.matrix = bone
        assertEqual(hierarchy.world(of: "3", attachments: hand), parent.matrix * bone * child.matrix)
        XCTAssertEqual(hand.asked, [SceneAttachedObject(id: "2", parentID: "1", attachment: "правая рука")])
        hand.matrix = nil
        assertEqual(hierarchy.world(of: "2", attachments: hand), parent.matrix * child.matrix)
        assertEqual(hierarchy.world(of: "2"), parent.matrix * child.matrix, "no provider: no attachment")
    }

    // MARK: - Orthographic agreement

    /// With tilts only on the leaf, the orthographic view of the 3D world is the 2D path's
    /// `SceneAffineTransform`, depth and all (`origin.z` and `scale.z` don't show).
    func testOrthographicViewEqualsThe2DPath() {
        var generator = SplitMix64(state: 0x2d)
        for _ in 0..<200 {
            func planar(tilt: Bool) -> SceneLocalTransform {
                let a = randomAngles(&generator)
                return SceneLocalTransform(origin: SIMD2(Float.random(in: -500...500, using: &generator),
                                                         Float.random(in: -500...500, using: &generator)),
                                           scale: SIMD2(Float.random(in: 0.1...3, using: &generator),
                                                        Float.random(in: 0.1...3, using: &generator)),
                                           angle: a.z, tilt: tilt ? SIMD2(a.x, a.y) : .zero)
            }
            let locals = [planar(tilt: false), planar(tilt: false), planar(tilt: true)]
            let depth = { SceneLocalTransform3D($0, originZ: Float.random(in: -100...100, using: &generator),
                                                scaleZ: Float.random(in: 0.1...3, using: &generator)) }
            let flat = SceneTransformHierarchy(nodes: [
                "1": .init(parentID: nil, local: locals[0]), "2": .init(parentID: "1", local: locals[1]),
                "3": .init(parentID: "2", local: locals[2]),
            ])
            // Depth only on the leaf: the parents' z would move the leaf's origin through no tilt.
            let deep = SceneTransformHierarchy3D(nodes: [
                "1": .init(parentID: nil, local: SceneLocalTransform3D(locals[0])),
                "2": .init(parentID: "1", local: SceneLocalTransform3D(locals[1])),
                "3": .init(parentID: "2", local: depth(locals[2])),
            ])
            let projected = SceneWorldMatrix.orthographic(deep.world(of: "3"))
            let expected = flat.world(of: "3")
            XCTAssertLessThanOrEqual(simd_length(projected.translation - expected.translation), 1e-2)
            XCTAssertLessThanOrEqual(simd_length(projected.linear.columns.0 - expected.linear.columns.0), 1e-4)
            XCTAssertLessThanOrEqual(simd_length(projected.linear.columns.1 - expected.linear.columns.1), 1e-4)
        }
    }

    // MARK: - Live values

    /// Scripts win over timelines, timelines over the authored node; all three components.
    func testLive3DValuesTakeScriptsThenTimelinesThenAuthored() throws {
        let object = try objects(#"[{"id": 1, "origin": "1 2 3", "scale": "1 1 4", "angles": "0 0 0.5"}]"#)[0]
        let motion = SceneObjectMotion(object: object, bindings: SceneLayerBindings())
        let authored = SceneLocalTransform3D(object: object)
        XCTAssertEqual(motion.local3D(authored: authored), authored)

        var animation = SceneObjectAnimation()
        animation.origin = SIMD3(5, 6, 7)
        animation.angles = SIMD3(0.1, 0.2, 0.3)
        let animated = motion.local3D(authored: authored, animation: animation)
        XCTAssertEqual(animated, SceneLocalTransform3D(origin: SIMD3(5, 6, 7), scale: SIMD3(1, 1, 4), angles: SIMD3(0.1, 0.2, 0.3)))

        var script = SceneScriptObjectState(values: [Float](repeating: 0, count: SceneScriptObjectTable.Layout.stride))
        for (field, value) in [(SceneScriptObjectField.origin, SIMD3<Float>(8, 9, 10)), (.scale, SIMD3(2, 2, 2))] {
            script.owned.insert(field)
            for index in 0..<3 { script.values[field.offset + index] = value[index] }
        }
        let scripted = motion.local3D(authored: authored, animation: animation, script: script)
        XCTAssertEqual(scripted, SceneLocalTransform3D(origin: SIMD3(8, 9, 10), scale: SIMD3(2, 2, 2), angles: SIMD3(0.1, 0.2, 0.3)))
        XCTAssertEqual(motion.local3D(authored: authored, animation: animation, script: script, scriptValues: false), animated)
        // The 2D path sees the same x and y.
        XCTAssertEqual(motion.local(animation: animation, script: script), scripted.planar)
    }

    /// User bindings move the authored node by their change since the build, z included.
    func testUserBindingsMoveTheAuthoredNode() throws {
        let scene = try decodeTolerant(WEScene.self, from: Fixtures.data("Scenes/bindings/scene.json"))
        let object = scene.objects[0]
        let built = PropertyContext(properties: ["pos": "100 200 0", "size": "0.2"])
        let bindings = SceneLayerBindings(object: object, builtWith: built)
        let authored = SceneLocalTransform3D(origin: SIMD3(100, 200, 0), scale: SIMD3(repeating: 0.2), angles: SIMD3(0, 0, 0.5))
        XCTAssertEqual(SceneObjectMotion.bound(authored, by: bindings, in: built), authored)
        let now = PropertyContext(properties: ["pos": "110 190 30", "size": "0.4"])
        let moved = SceneObjectMotion.bound(authored, by: bindings, in: now)
        assertEqual(moved.origin, SIMD3(110, 190, 30))
        assertEqual(moved.scale, SIMD3(repeating: 0.4))
        XCTAssertEqual(moved.angles, authored.angles)
    }

    /// The spatial content carries the 3D hierarchy with WE's root default.
    func testSpatialContentCarriesTheHierarchy() throws {
        var scene = try decodeTolerant(WEScene.self, from: Data(#"""
        {"camera": {}, "general": {}, "objects": [{"id": 3, "origin": "0 0 5"}, {"id": 4, "parent": 3}]}
        """#.utf8))
        scene.objects = SceneObjectIdentity.assigningFallbackIDs(scene.objects)
        let content = SceneSpatialContentBuilder(readFile: { _ in nil }, wallpaperName: "test")
            .build(scene, context: PropertyContext())
        XCTAssertEqual(content.transforms, SceneTransformHierarchy3D(objects: scene.objects))
        XCTAssertEqual(SceneWorldMatrix.translation(content.transforms.world(of: "4")), SIMD3(0, 0, 5))
    }
}
