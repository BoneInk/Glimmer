import JavaScriptCore
import XCTest
import simd
@testable import OpenWallpaperEngine

/// The model half of the rig API (docs/models-plan.md §2.8, §4.3 M6): a model object's record
/// carries its rig like a puppet image's, so scripts get its animation layers and attachment
/// points; WE binds no bone API on models (0x140227814), so those calls answer as on a layer
/// without a rig and send nothing.
final class ModelScriptRigTests: XCTestCase {
    private func fixture() throws -> SceneScriptObjectFixture {
        var model = SceneScriptObjectDescription.make(.model, id: 7, name: "robot")
        model.rig = SceneScriptRigTests.rig
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [model])))
        f.runtime.load()
        f.evaluate("var robot = thisScene.getLayer('robot');")
        return f
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? { f.evaluate(script)?.toString() }

    func testAModelHasLayersAndAttachmentsButNoBoneAPI() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        XCTAssertEqual(string(f, """
            var idle = robot.getAnimationLayer('idle');
            [robot.getAnimationLayerCount(), idle.name, idle.fps, robot.getAttachmentIndex('grip'),
             robot.getBoneCount(), robot.getBoneIndex('arm'), robot.getBoneParentIndex('hand')].join()
            """), "1,idle,30,0,0,-1,-1")
        XCTAssertEqual(string(f, "robot.getBoneTransform('hand').m[13]"), "0", "no bone: the identity")
        XCTAssertEqual(string(f, "var o = robot.getAttachmentOrigin('grip'); [o.x, o.y].join()"), "31,7",
                       "the hand's model matrix times the attachment's")
        f.evaluate("""
            robot.setLocalBoneOrigin('arm', new Vec3(7, 8, 0)); robot.setBoneTransform(0, new Mat4());
            idle.rate = 2; robot.playSingleAnimation('wave');
            """)
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = f.host.takeCommands().compactMap { command -> SceneScriptRigCommand? in
            if case .rig(_, let rig) = command { return rig }
            return nil
        }
        XCTAssertFalse(commands.contains { if case .setLocal = $0 { return true }; if case .setWorld = $0 { return true }; return false },
                       "no bone writes from a model")
        XCTAssertTrue(commands.contains(.setLayer(key: 47, field: .rate, value: 2)), "\(commands)")
        XCTAssertTrue(commands.contains { if case .createLayer(_, "wave", _, true) = $0 { return true }; return false }, "\(commands)")
    }

    /// The renderer's side: a model's animator takes layer commands and ignores bone writes.
    func testTheModelAnimatorTakesLayerCommandsOnly() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try XCTUnwrap(SceneModelRenderer(device: device, archive: nil))
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        let clip = try XCTUnwrap(model.animations?.first)
        let plan = SceneModelPlan(path: "rig.mdl", meshes: [], bounds: .unbounded, skeleton: model.skeleton,
                                  clips: model.animations ?? [], attachments: [MDLAttachment(bone: 1, name: "tip",
                                                                                             matrix: ScenePuppetTests.translation(SIMD3(0, 3, 0)))])
        let object = SceneModelObject(id: "9", name: "rig", order: 0, authored: WESceneModel(source: .path("rig.mdl")),
                                      animationLayers: [WEAnimationLayer(animation: clip.id, id: 3, name: "a")], plan: plan)
        renderer.setContent([object], content: SceneMetalContent(size: SIMD2(8, 8), layers: [], particleSystems: [],
                                                                 bloom: SceneBloomSettings(enabled: false, strength: 0, threshold: 0.7,
                                                                                           tint: SIMD3(repeating: 1))))
        XCTAssertEqual(renderer.riggedObjectIDs, ["9"])
        let animator = try XCTUnwrap(renderer.animator(for: "9"))
        XCTAssertEqual(animator.layerStates.map(\.key), [3])
        let before = animator.locals
        renderer.perform(.setLocal(bone: 0, matrix: ScenePuppetTests.translation(SIMD3(50, 0, 0))), on: "9")
        XCTAssertEqual(animator.locals, before, "no bone API on models")
        renderer.perform(.setLayer(key: 3, field: .rate, value: 3), on: "9")
        XCTAssertEqual(animator.layerStates.first?.rate, 3)

        // A child hanging from the attachment: the bone's model-space matrix times the MDAT matrix.
        let world = try XCTUnwrap(renderer.attachments.attachmentWorld(SceneAttachedObject(id: "10", parentID: "9", attachment: "tip")))
        XCTAssertEqual(world, animator.worlds[1] * ScenePuppetTests.translation(SIMD3(0, 3, 0)))
        XCTAssertNil(renderer.attachments.attachmentWorld(SceneAttachedObject(id: "10", parentID: "9", attachment: "nope")))
    }

    /// 3159348391's moves: `getAnimationLayer('kick').getAnimation('go')` is the timeline on the
    /// layer's own `blend` (`animationlayers[1].blend`), found by its name or its field's key; the
    /// object's and the scene's `getAnimation(name)` don't reach it, and `play()` sends the
    /// timeline call the renderer applies to that site.
    func testALayersOwnTimelinesAreFoundThroughTheLayer() throws {
        var model = SceneScriptObjectDescription.make(.model, id: 124, name: "dancer", animations: [
            .init(name: "go", fps: 30, frameCount: 15, duration: 0.5, property: "animationlayers.1.blend"),
            .init(name: "spin", fps: 30, frameCount: 30, duration: 1, playing: true, property: "angles"),
        ])
        var rig = SceneScriptRigTests.rig
        rig.layers = [.init(key: 47, name: "idle", clip: 0, additive: false, authored: 0),
                      .init(key: 48, name: "kick", clip: 1, additive: false, blend: 0, authored: 1)]
        model.rig = rig
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [model])))
        f.runtime.load()
        XCTAssertEqual(f.evaluate("""
            var dancer = thisScene.getLayer('dancer'), kick = dancer.getAnimationLayer('kick'), go = kick.getAnimation('go');
            [go !== null, go === kick.getAnimation('blend'), go.name, go.frameCount, go.isPlaying(), kick.getAnimation('spin'),
             dancer.getAnimationLayer('idle').getAnimation('go'), dancer.getAnimation('go'), thisScene.getAnimation('go'),
             dancer.getAnimation('spin') !== null, dancer.createAnimationLayer('wave').getAnimation('go')].join()
            """)?.toString(), "true,true,go,15,false,,,,,true,")
        f.evaluate("go.play();")
        f.runtime.frame(deltaTime: 1.0 / 60)
        let calls = f.host.takeCommands().compactMap { command -> (SceneScriptAnimationReference, SceneScriptObjectCommand.AnimationAction)? in
            if case let .animation(reference, action) = command { return (reference, action) }
            return nil
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0.name, "go")
        XCTAssertEqual(calls.first?.0.slot, try XCTUnwrap(f.model.slot(forObjectID: 124)))
        XCTAssertEqual(calls.first?.1, .play)
        XCTAssertEqual(f.store.animationDescriptions[try XCTUnwrap(calls.first?.0.animationSlot)]?.property,
                       "animationlayers.1.blend")
    }

    /// The renderer's side: an authored layer's `blend` timeline is the wallpaper's
    /// `SceneAnimationSet` sample of its site (`animationlayers[l].blend` of the object) when the
    /// set has one, so scripts' `play()` raises the move; without one it runs on its own clock.
    func testALayersBlendFollowsTheWallpapersTimeline() throws {
        let model = try MDLModel(contentsOf: Fixtures.url("Models/v13-puppet.mdl"))
        let skeleton = try XCTUnwrap(model.skeleton)
        let clips = model.animations ?? []
        let clip = try XCTUnwrap(clips.first)
        let json = """
            [{"animation": \(clip.id), "id": 3, "name": "idle", "blend": 1},
             {"animation": \(clip.id), "id": 4, "name": "kick", "blend": {"value": 0, "animation": {
                 "c0": [{"frame": 0, "value": 0}, {"frame": 3, "value": 1}, {"frame": 12, "value": 1}, {"frame": 15, "value": 0}],
                 "options": {"fps": 30, "length": 15, "mode": "single", "name": "go", "startpaused": true}}}}]
            """
        let layers = try JSONDecoder().decode([WEAnimationLayer].self, from: Data(json.utf8))
        XCTAssertEqual(layers.map(\.position), [0, 1])

        struct Values: SceneValueContext {
            var blend: Float?
            func userProperty(_ name: String) -> String? { nil }
            func animationValue(_ site: SceneAnimationSite) -> [Float]? {
                site == SceneAnimationSite(owner: .animationLayer(object: 124, layer: 1), key: "blend") ? blend.map { [$0] } : nil
            }
        }
        let shared = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: layers, model: true, objectID: 124)
        shared.advance(delta: 1 / 30, values: Values(blend: 0.75))
        XCTAssertEqual(shared.layerStates.map(\.blend), [1, 0.75])
        shared.advance(delta: 1 / 30, values: Values(blend: 0.25))
        XCTAssertEqual(shared.layerStates.map(\.blend), [1, 0.25])

        // Without the set's sample: its own start-paused clock holds the first key.
        let own = ScenePuppetAnimator(skeleton: skeleton, clips: clips, layers: layers, model: true)
        for _ in 0..<10 { own.advance(delta: 1 / 30, values: Values(blend: 0.75)) }
        XCTAssertEqual(own.layerStates.map(\.blend), [1, 0])
    }

    /// PaRappa's model objects describe their rigs to scripts (skipped without the library).
    func testALibraryModelDescribesItsRig() throws {
        let directory = LibrarySweepTests.libraryRoot.appending(path: "3159348391", directoryHint: .isDirectory)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appending(path: "models/parappa/parappa.mdl").path),
                          "PaRappa not in the library")
        let describer = SceneScriptSceneDescriber(userProperties: SceneScriptUserProperties(), file: { path in
            FileManager.default.contents(atPath: directory.appending(path: path).path)
        })
        let model = try MDLModel.load(path: "models/parappa/parappa.mdl", package: nil, directory: directory)
        let clip = try XCTUnwrap(model.animations?.first)
        let rig = try XCTUnwrap(describer.rig(modelObject: "models/parappa/parappa.mdl",
                                              animationLayers: .array([.object(["animation": .number(Double(clip.id)), "id": .number(5),
                                                                                "name": .string("dance")])])))
        XCTAssertEqual(rig.bones.count, 115)
        XCTAssertEqual(rig.layers.map(\.key), [5])
        XCTAssertNil(describer.rig(modelObject: "models/sun/sun.mdl", animationLayers: nil), "a model without bones has no rig")
    }
}
