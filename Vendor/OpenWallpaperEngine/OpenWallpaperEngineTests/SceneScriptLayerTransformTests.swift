import JavaScriptCore
import XCTest
import simd
@testable import OpenWallpaperEngine

/// `ILayer.setParent`, `lookAt`, `lookAtYaw`, `rotateObjectSpace` and
/// `IEffectLayer.transformAttachmentToTexture` (objects-transforms.js), and the parent change's
/// way through the command ring into the renderer's parent graphs.
final class SceneScriptLayerTransformTests: XCTestCase {
    private func fixture() throws -> SceneScriptObjectFixture {
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptObjectModelTests.sceneDescription(),
                                                                       describe: SceneScriptObjectModelTests.describe))
        f.runtime.load()
        f.evaluate("""
            var bg = thisScene.getLayer('background'), clock = thisScene.getLayer('clock'),
                group = thisScene.getLayer('group');
            function angles(layer) {
                var a = layer.angles;
                return [a.x, a.y, a.z].map(function (v) { return Math.round(v * 1000) / 1000 + 0; }).join();
            }
            """)
        return f
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? { f.evaluate(script)?.toString() }

    private func slot(_ f: SceneScriptObjectFixture, _ id: Int) throws -> Int { try XCTUnwrap(f.model.slot(forObjectID: id)) }

    /// Writes the world matrix the renderer would have left in the table.
    private func setWorld(_ f: SceneScriptObjectFixture, slot: Int, _ matrix: simd_float4x4) {
        let base = SceneScriptObjectTable.index(slot: slot, field: SceneScriptObjectTable.Layout.worldMatrix)
        for column in 0..<4 {
            for row in 0..<4 { f.store.table.values[base + column * 4 + row] = matrix[column][row] }
        }
    }

    private func parentCommands(_ f: SceneScriptObjectFixture) -> [SceneScriptObjectCommand] {
        f.host.takeCommands().filter {
            if case .setParent = $0 { return true }
            return false
        }
    }

    func testRotateObjectSpaceTurnsAboutTheLayersOwnAxes() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate("group.angles = new Vec3(0, 0, 10); group.rotateObjectSpace(new Vec3(0, 0, 30));")
        XCTAssertEqual(string(f, "angles(group)"), "0,0,40")
        // Its x axis points up after 90° about z; a turn about that axis is x first: (90, 0, 90),
        // where a turn about the parent's x would tilt it about the scene's x instead.
        f.evaluate("group.angles = new Vec3(0, 0, 90); group.rotateObjectSpace(new Vec3(90, 0, 0));")
        XCTAssertEqual(string(f, "angles(group)"), "90,0,90")
        let slot = try slot(f, 5)
        XCTAssertEqual(Double(f.table(slot, .angles)[0]), .pi / 2, accuracy: 1e-5, "radians in the table")
        XCTAssertEqual(f.store.table.dirty[slot], 1, "a member write the renderer reads back")
        f.evaluate("group.rotateObjectSpace(); group.rotateObjectSpace('x');")
        XCTAssertEqual(string(f, "angles(group)"), "90,0,90", "no vector: nothing")
    }

    /// The camera path's basis (0x14019d920 → 0x1401f31f2): a layer's local +z points at the
    /// centre (WE aims it at the mirror image, 0x1401dfcc5), a camera's −z; `lookAtYaw` drops the
    /// part along `up`.
    func testLookAtAndLookAtYaw() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate("group.origin = new Vec3(0, 0, 0); group.lookAt(new Vec3(0, -5, 5));")
        XCTAssertEqual(string(f, "angles(group)"), "45,0,0", "+z down and forward: pitched up 45°")
        f.evaluate("group.lookAtYaw(new Vec3(0, -5, 5));")
        XCTAssertEqual(string(f, "angles(group)"), "0,0,0", "upright: the heading alone")
        f.evaluate("group._record.kind = 'camera'; group.lookAt(new Vec3(0, 5, -5)); group._record.kind = 'group';")
        XCTAssertEqual(string(f, "angles(group)"), "45,0,0", "a camera's −z points at the centre")
        f.evaluate("group.lookAtYaw(new Vec3(-5, 5, 0));")
        XCTAssertEqual(string(f, "var m = group.angles; Math.round(m.y)"), "-90", "a heading along +x")
        // Relative to the layer's origin; a centre on the eye or an up along the view changes nothing.
        f.evaluate("""
            group.origin = new Vec3(10, 0, 0); group.angles = new Vec3(0, 0, 0);
            group.lookAt(new Vec3(10, 0, 0)); group.lookAt(new Vec3(10, 5, 0), new Vec3(0, 1, 0)); group.lookAt();
            """)
        XCTAssertEqual(string(f, "angles(group)"), "0,0,0")
        f.evaluate("group.lookAt(new Vec3(10, -5, 5), new Vec3(0, 1, 0));")
        XCTAssertEqual(string(f, "angles(group)"), "45,0,0")
    }

    func testSetParentChangesTheParentAndReachesTheHost() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        let clockSlot = try slot(f, 2), groupSlot = try slot(f, 5)
        _ = parentCommands(f)
        XCTAssertEqual(string(f, "clock.getParent() === bg"), "true")
        f.evaluate("clock.setParent(undefined);")
        XCTAssertEqual(string(f, "[clock.getParent() === undefined, bg.getChildren().length].join()"), "true,0")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(parentCommands(f), [.setParent(slot: clockSlot, parent: nil, attachment: nil)])

        f.evaluate("clock.setParent('group'); group.setParent(clock); group.setParent(group); clock.setParent('nope');")
        XCTAssertEqual(string(f, "[clock.getParent() === group, group.getParent() === undefined].join()"), "true,true",
                       "a layer never becomes its own ancestor; an unknown parent changes nothing")
        f.evaluate("clock.setParent(1, 'grip');")
        XCTAssertEqual(string(f, "clock.getParent() === bg"), "true", "a number is a layer id")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(parentCommands(f), [.setParent(slot: clockSlot, parent: groupSlot, attachment: nil),
                                           .setParent(slot: clockSlot, parent: try slot(f, 1), attachment: "grip")])
    }

    /// adjustTransforms: the layer's own transform becomes its world one in the new parent's space.
    func testSetParentKeepsTheWorldTransformWhenAsked() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        // The group turned 90° at (40, 10); the clock drawn at (100, 50), twice its size.
        setWorld(f, slot: try slot(f, 5), simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0),
                                                                   SIMD4(40, 10, 0, 1))))
        setWorld(f, slot: try slot(f, 2), simd_float4x4(columns: (SIMD4(2, 0, 0, 0), SIMD4(0, 2, 0, 0), SIMD4(0, 0, 1, 0),
                                                                   SIMD4(100, 50, 0, 1))))
        f.evaluate("clock.origin = new Vec3(1, 2, 7); clock.setParent(group, true);")
        XCTAssertEqual(string(f, "var o = clock.origin, s = clock.scale; [o.x, o.y, o.z, s.x, s.y].join()"), "40,-60,7,2,2",
                       "a planar world keeps the layer's own z")
        XCTAssertEqual(string(f, "angles(clock)"), "0,0,-90")
        f.evaluate("clock.setParent(undefined, true);")
        XCTAssertEqual(string(f, "var o = clock.origin; [o.x, o.y, Math.round(clock.angles.z)].join()"), "100,50,0",
                       "no parent: the world transform itself")
        f.evaluate("clock.origin = new Vec3(3, 4, 0); clock.setParent(group);")
        XCTAssertEqual(string(f, "var o = clock.origin; [o.x, o.y].join()"), "3,4", "without adjustTransforms it stays")
    }

    func testSetParentCommandDecoding() throws {
        let f = try fixture()
        let clockSlot = try slot(f, 2)
        _ = parentCommands(f)
        // Straight through the ring, as any script can push: a dead or own slot is dropped.
        f.evaluate("__rt.push(__rt.objects.OP.setParent, \(clockSlot), [\(clockSlot)]);")
        f.evaluate("__rt.push(__rt.objects.OP.setParent, \(clockSlot), [NaN]);")
        f.evaluate("__rt.push(__rt.objects.OP.setParent, \(clockSlot), [0], ['']);")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(parentCommands(f), [.setParent(slot: clockSlot, parent: 0, attachment: nil)])
    }

    /// The attachment's world in the layer's texture space: u right, v down, 0…1 over the quad.
    func testTransformAttachmentToTexture() throws {
        _ = try Fixtures.assets()
        var puppet = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        puppet.rig = SceneScriptRigTests.rig
        let plain = SceneScriptObjectDescription.make(.image, id: 6, name: "plain", values: [.size: [200, 100]])
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [puppet, plain])))
        f.runtime.load()
        // The bind pose puts the grip at (31, 7); the plain layer sits 50 left of and 25 below it.
        setWorld(f, slot: try slot(f, 6), simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                                                   SIMD4(-19, -18, 0, 1))))
        f.evaluate("var plain = thisScene.getLayer('plain'), t = plain.transformAttachmentToTexture('puppet', 'grip');")
        f.evaluate("function rounded(m) { return Array.from(m).map(function (v) { return Math.round(v * 1e6) / 1e6 + 0; }); }")
        XCTAssertEqual(string(f, "var r = rounded(t.m); [r[0], r[1], r[3], r[4], r[6], r[7], r[8]].join()"),
                       "0.005,0,0,-0.01,0.75,0.25,1")
        f.evaluate("plain.alignment = 'bottomleft';")
        XCTAssertEqual(string(f, "var l = rounded(plain.transformAttachmentToTexture(5, 0).m); [l[6], l[7]].join()"), "0.25,0.75",
                       "the quad hangs right of and above a bottom-left origin")
        XCTAssertEqual(string(f, """
            [plain.transformAttachmentToTexture('puppet', 'nope').m[6], plain.transformAttachmentToTexture('x', 'grip').m[6],
             thisScene.getLayer('puppet').transformAttachmentToTexture('puppet', 'grip').m[6]].join()
            """), "0,0,0", "a missing attachment or layer, or a layer without size: identity")
    }

    // MARK: - Renderer side

    func testHierarchiesReparent() {
        var planar = SceneTransformHierarchy(nodes: [
            "1": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(100, 100), scale: SIMD2(2, 2), angle: 0)),
            "2": .init(parentID: nil, local: SceneLocalTransform(origin: SIMD2(10, 0), scale: SIMD2(1, 1), angle: 0)),
        ])
        planar.setParent("2", to: "1", attachment: nil)
        XCTAssertEqual(planar.world(of: "2").translation, SIMD2(120, 100))
        planar.setParent("2", to: nil, attachment: "grip")
        XCTAssertEqual(planar.world(of: "2").translation, SIMD2(10, 0))
        XCTAssertNil(planar.nodes["2"]?.attachment, "no parent, no attachment")
        planar.setParent("9", to: nil, attachment: nil)
        XCTAssertNil(planar.nodes["9"], "unparenting an object without a node adds none")
        planar.setParent("9", to: "1", attachment: nil)
        XCTAssertEqual(planar.nodes["9"]?.parentID, "1", "a created layer gets a node under its parent")

        var spatial = SceneTransformHierarchy3D(nodes: [
            "1": .init(parentID: nil, local: SceneLocalTransform3D(origin: SIMD3(0, 0, 5), scale: SIMD3(repeating: 1), angles: .zero)),
            "2": .init(parentID: nil, local: SceneLocalTransform3D(origin: SIMD3(1, 0, 0), scale: SIMD3(repeating: 1), angles: .zero),
                       attachment: "old"),
        ])
        spatial.setParent("2", to: "1", attachment: "hand")
        XCTAssertEqual(spatial.nodes["2"]?.attachment, "hand")
        XCTAssertEqual(SceneWorldMatrix.translation(spatial.world(of: "2")), SIMD3(1, 0, 5))
    }
}
