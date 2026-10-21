import JavaScriptCore
import XCTest
import simd
@testable import OpenWallpaperEngine

/// The image half of the rig API (docs/models-plan.md §2.8, §4.3 P2) on a fixture puppet:
/// `IImageLayer`'s animation layers and bones, `IAnimationLayer`, `ILayer` attachments, through
/// the rig buffer and the commands the animator gets.
final class SceneScriptRigTests: XCTestCase {
    /// Three bones (a root at (10, 0), an arm 20 right of it, a hand 5 above the arm), two clips,
    /// one authored layer and one attachment on the hand.
    static let rig: SceneScriptRigDescription = {
        func translation(_ x: Float, _ y: Float) -> [Float] { SceneScriptRigLayout.components(ScenePuppetTests.translation(SIMD3(x, y, 0))) }
        return SceneScriptRigDescription(
            bones: [.init(name: "root", parent: -1, local: translation(10, 0), model: translation(10, 0)),
                    .init(name: "arm", parent: 0, local: translation(20, 0), model: translation(30, 0)),
                    .init(name: "hand", parent: 1, local: translation(0, 5), model: translation(30, 5))],
            clips: [.init(id: 41, name: "idle", fps: 30, frameCount: 60, duration: 2),
                    .init(id: 42, name: "wave", fps: 10, frameCount: 10, duration: 1)],
            layers: [.init(key: 47, name: "idle", clip: 0, additive: false, rate: 1, blend: 1, visible: true)],
            attachments: [.init(name: "grip", bone: 2, matrix: translation(1, 2))])
    }()

    private func fixture() throws -> SceneScriptObjectFixture {
        var image = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        image.rig = Self.rig
        let plain = SceneScriptObjectDescription.make(.image, id: 6, name: "plain")
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [image, plain])))
        f.runtime.load()
        f.evaluate("var puppet = thisScene.getLayer('puppet'), plain = thisScene.getLayer('plain');")
        return f
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? { f.evaluate(script)?.toString() }

    private func rigCommands(_ f: SceneScriptObjectFixture) -> [SceneScriptRigCommand] {
        f.host.takeCommands().compactMap { command in
            if case .rig(_, let rig) = command { return rig }
            return nil
        }
    }

    func testBones() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        XCTAssertEqual(string(f, """
            [puppet.getBoneCount(), puppet.getBoneIndex('arm'), puppet.getBoneIndex('nope'), puppet.getBoneParentIndex('hand'),
             puppet.getBoneParentIndex(0), plain.getBoneCount()].join()
            """), "3,1,-1,1,-1,0")
        XCTAssertEqual(string(f, "var t = puppet.getLocalBoneTransform('arm').m; [t[12], t[13]].join()"), "20,0")
        XCTAssertEqual(string(f, "var o = puppet.getLocalBoneOrigin(2); [o.x, o.y, o.z].join()"), "0,5,0")
        XCTAssertEqual(string(f, "puppet.getBoneTransform('hand').m[13]"), "5", "the bind pose until the renderer's first frame")

        // Local writes read back at once and reach the animator.
        f.evaluate("puppet.setLocalBoneOrigin('arm', { x: 7, y: 8, z: 0 }); puppet.setLocalBoneAngles(1, { x: 0, y: 0, z: Math.PI / 2 });")
        XCTAssertEqual(string(f, """
            var a = puppet.getLocalBoneAngles('arm'), o = puppet.getLocalBoneOrigin('arm');
            [a.z.toFixed(4), Math.round(a.x), o.x, o.y].join()
            """), "1.5708,0,7,8")
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = rigCommands(f)
        XCTAssertEqual(commands.count, 2)
        guard case let .setLocal(bone, matrix)? = commands.last else { return XCTFail("\(commands)") }
        XCTAssertEqual(bone, 1)
        XCTAssertEqual(matrix.columns.3, SIMD4(7, 8, 0, 1))
        XCTAssertEqual(matrix.columns.0.y, 1, accuracy: 1e-6, "turned 90° about z: x goes to y")

        f.evaluate("var m = new Mat4(); m.m[12] = 100; puppet.setBoneTransform('root', m); puppet.setBoneTransform(9, m);")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(rigCommands(f), [.setWorld(bone: 0, matrix: ScenePuppetTests.translation(SIMD3(100, 0, 0)))])
        XCTAssertEqual(string(f, "puppet.getBoneTransform(0).m[12]"), "100")
    }

    func testAnimationLayers() throws {
        let f = try fixture()
        XCTAssertEqual(string(f, """
            var idle = puppet.getAnimationLayer('idle');
            [puppet.getAnimationLayerCount(), idle === puppet.getAnimationLayer(0), idle.name, idle.fps, idle.frameCount,
             idle.duration, idle.rate, idle.visible, idle.isPlaying(), puppet.getAnimationLayer('nope'), plain.getAnimationLayerCount()].join()
            """), "1,true,idle,30,60,2,1,true,true,,0")
        f.evaluate("idle.rate = 2; idle.blend = 0.5; idle.visible = false; idle.pause(); idle.setFrame(15);")
        XCTAssertEqual(string(f, "[idle.rate, idle.blend, idle.visible, idle.isPlaying(), idle.getFrame()].join()"),
                       "2,0.5,false,false,15")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(rigCommands(f), [.setLayer(key: 47, field: .rate, value: 2), .setLayer(key: 47, field: .blend, value: 0.5),
                                        .setLayer(key: 47, field: .visible, value: 0), .playback(key: 47, .pause),
                                        .playback(key: 47, .setFrame(15))])

        // Created layers: by clip name with a config, or a JSON config; autosort before additive ones.
        XCTAssertEqual(string(f, """
            var add = puppet.createAnimationLayer({ animation: 'wave', name: 'add', additive: true });
            var once = puppet.playSingleAnimation('wave', { autosort: true, blendin: true, rate: 3 });
            var bad = puppet.createAnimationLayer('missing');
            [puppet.getAnimationLayerCount(), puppet.getAnimationLayer(1).name, puppet.getAnimationLayer(2).name, once.rate,
             bad].join()
            """), "3,wave,add,3,")
        f.runtime.frame(deltaTime: 1.0 / 60)
        let created = rigCommands(f)
        XCTAssertEqual(created.count, 2)
        guard case let .createLayer(addKey, clip, config, single)? = created.first,
              case let .createLayer(_, _, onceConfig, onceSingle)? = created.last else { return XCTFail("\(created)") }
        XCTAssertEqual(clip, "wave")
        XCTAssertEqual(config.name, "add")
        XCTAssertTrue(config.additive)
        XCTAssertFalse(single)
        XCTAssertTrue(onceSingle)
        XCTAssertTrue(onceConfig.autosort && onceConfig.blendIn)
        XCTAssertEqual(onceConfig.rate, 3)

        XCTAssertEqual(string(f, "[puppet.destroyAnimationLayer(add), puppet.destroyAnimationLayer('add'), puppet.getAnimationLayerCount()].join()"),
                       "true,false,2")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(rigCommands(f), [.destroyLayer(key: addKey)])
    }

    /// The renderer's feedback replaces the buffer's state; a clip's end calls `addEndedCallback`.
    func testFeedbackAndEndedCallbacks() throws {
        let f = try fixture()
        f.evaluate("var ends = 0; puppet.getAnimationLayer(0).addEndedCallback(function () { ends += 1; });")
        let slot = try XCTUnwrap(f.store.rigSlot(of: try XCTUnwrap(f.model.slot(forObjectID: 5))))
        let world = ScenePuppetTests.translation(SIMD3(500, 300, 0))
        var feedback = SceneScriptRigFeedback(
            layers: [.init(key: 47, name: "idle", clip: 0, time: 0.5, frame: 15, flags: [], rate: 1, blend: 1, visible: true,
                           additive: false)],
            locals: (0..<3).map { _ in matrix_identity_float4x4 }, worlds: (0..<3).map { _ in world }, ended: [47])
        let mirror = SceneScriptRigMirror()
        mirror.publish([5: feedback], into: f.store.rigs) { $0 == 5 ? slot : nil }
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(string(f, "[ends, puppet.getAnimationLayer(0).getFrame(), puppet.getBoneTransform(2).m[12]].join()"), "1,15,500")
        feedback.ended = []
        mirror.publish([5: feedback], into: f.store.rigs) { $0 == 5 ? slot : nil }
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(string(f, "ends"), "1", "once per end")

        // Attachments: the bone's world times the attachment's matrix.
        XCTAssertEqual(string(f, """
            var o = puppet.getAttachmentOrigin('grip'), a = puppet.getAttachmentAngles(0);
            [puppet.getAttachmentIndex('grip'), puppet.getAttachmentIndex('x'), o.x, o.y, a.z,
             puppet.getAttachmentMatrix('grip').m[13]].join()
            """), "0,-1,501,302,0,302")
    }

    /// WE 2.8's units for the bone and attachment angles (docs/models-plan.md §5.24,
    /// tools/peer/requests/owe-beta3/models-open/524-bone-angle-units/README.md): radians, with a
    /// bone by name or index; a bone at Angles Z = 90 in the editor (stored "0 -0 1.57080") logs
    /// 0,0,1.5708 for both. The layers' `angles` stay degrees.
    func testBoneAndAttachmentAnglesAreRadians() throws {
        var image = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        let quarter = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1)))
        var rig = Self.rig
        rig.bones[1] = .init(name: "arm", parent: 0, local: SceneScriptRigLayout.components(quarter),
                             model: SceneScriptRigLayout.components(quarter))
        rig.attachments = [.init(name: "grip", bone: 1, matrix: SceneScriptRigLayout.components(matrix_identity_float4x4))]
        image.rig = rig
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [image])))
        f.runtime.load()
        f.evaluate("var puppet = thisScene.getLayer('puppet');")
        func fmt(_ v: String) -> String { "[\(v).x.toFixed(4), \(v).y.toFixed(4), \(v).z.toFixed(4)].join()" }
        XCTAssertEqual(string(f, fmt("puppet.getLocalBoneAngles('arm')")), "0.0000,0.0000,1.5708")
        XCTAssertEqual(string(f, fmt("puppet.getLocalBoneAngles(1)")), "0.0000,0.0000,1.5708", "a numeric index")
        XCTAssertEqual(string(f, fmt("puppet.getAttachmentAngles('grip')")), "0.0000,0.0000,1.5708")

        // A write in radians reads back the same and turns the bone that far.
        f.evaluate("puppet.setLocalBoneAngles('arm', { x: 0, y: 0, z: Math.PI });")
        XCTAssertEqual(string(f, fmt("puppet.getLocalBoneAngles(1)")), "0.0000,0.0000,3.1416")
        f.runtime.frame(deltaTime: 1.0 / 60)
        guard case let .setLocal(bone, matrix)? = rigCommands(f).last else { return XCTFail("no local write") }
        XCTAssertEqual(bone, 1)
        XCTAssertEqual(matrix.columns.0.x, -1, accuracy: 1e-5, "half a turn, not π degrees")
        XCTAssertEqual(matrix.columns.0.y, 0, accuracy: 1e-5)
    }

    /// WE 2.8 with no bone (docs/models-plan.md §5.31,
    /// tools/peer/requests/owe-beta3/models-open/531-impulse-no-bone/README.md): no arguments, or
    /// the vectors alone, return undefined, throw nothing and move nothing.
    func testBonePhysicsWithoutABoneDoesNothing() throws {
        let f = try fixture()
        _ = f.host.takeCommands()
        XCTAssertEqual(string(f, """
            (function () {
                try {
                    return [typeof puppet.applyBonePhysicsImpulse(),
                            typeof puppet.applyBonePhysicsImpulse({ x: 0, y: 0, z: 0 }, { x: 0, y: 0, z: 45 }),
                            typeof puppet.resetBonePhysicsSimulation()].join();
                } catch (e) { return 'threw ' + e; }
            })()
            """), "undefined,undefined,undefined")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(rigCommands(f), [])
    }

    /// A puppet's rig from the library: the Knight's bones and its `idle` layer.
    func testTheKnightsRigDescription() throws {
        let directory = LibrarySweepTests.libraryRoot.appending(path: "2515150033", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path), "wallpaper library not present")
        let describer = SceneScriptSceneDescriber(userProperties: SceneScriptUserProperties(), file: { path in
            FileManager.default.contents(atPath: directory.appending(path: path).path)
        })
        let rig = try XCTUnwrap(describer.rig(model: "models/centurion 1080p_sheet.json",
                                              animationLayers: .array([.object(["animation": .number(41), "id": .number(47),
                                                                                "name": .string("idle")])])))
        XCTAssertEqual(rig.bones.count, 10)
        XCTAssertEqual(rig.layers.map(\.key), [47])
        XCTAssertEqual(rig.clips[rig.layers[0].clip].id, 41)
    }
}
