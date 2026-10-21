import XCTest
@testable import OWESceneEditing

/// Depth parallax through the overlay, as both editors apply it: WE's effect bound to a generated
/// depth map on a layer, on a fullscreen layer above a particle system or the whole scene; its
/// strength; a new depth map; removal; one undo step each; and the scene.json it bakes into.
@MainActor
final class DepthParallaxEditTests: XCTestCase {
    private var session: SceneEditSession!
    private let texture = "depth/editor_logo-0123456789ab"
    private let newer = "depth/editor_logo-ba9876543210"

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
    }

    private func applied() throws -> Data { try session.overlay.applied(to: Fixtures.sceneData) }

    private func depthEffect(in object: [String: Any]) -> [String: Any]? {
        (object["effects"] as? [[String: Any]])?.last { ($0["file"] as? String) == SceneDepthParallax.effectFile }
    }

    private func firstPass(_ effect: [String: Any]) -> [String: Any] {
        (effect["passes"] as? [[String: Any]])?.first ?? [:]
    }

    // MARK: On a layer

    func testApplyAddsWEsEffectBoundToTheDepthMap() throws {
        let key = try XCTUnwrap(session.applyDepthParallax(texture: texture, strength: 0.6, to: 13, actionName: "Apply"))
        XCTAssertEqual(key, "+1")
        XCTAssertEqual(session.depthParallaxTexture(of: 13), texture)
        XCTAssertEqual(try XCTUnwrap(session.depthParallaxStrength(of: 13)), 0.6, accuracy: 1e-9)

        let effect = try XCTUnwrap(depthEffect(in: try Fixtures.object(13, in: try applied())))
        let pass = firstPass(effect)
        XCTAssertEqual(pass["textures"] as? NSArray, [NSNull(), texture] as NSArray, "slot 1 is g_Texture1, the depth map")
        XCTAssertEqual((pass["combos"] as? [String: Any])?["QUALITY"] as? Int, SceneDepthParallax.defaultQuality)
        let constants = try XCTUnwrap(pass["constantshadervalues"] as? [String: Any])
        XCTAssertEqual(SceneVector.components(SceneJSONValue(any: constants["scale"])), [0.6, 0.6], "linked, as WE writes it")
        XCTAssertEqual(constants["sens"] as? Double, SceneDepthParallax.defaultPerspective)
        XCTAssertEqual(constants["center"] as? Double, SceneDepthParallax.defaultCenter)
        XCTAssertEqual(effect["visible"] as? Bool, true)

        // Round trip through the file the editor saves.
        let decoded = try SceneEditOverlay.decoded(from: try session.overlay.encoded())
        XCTAssertEqual(decoded, session.overlay)

        session.undo()
        XCTAssertNil(session.depthParallaxEffect(of: 13))
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testAnAuthoredLayerKeepsItsEffectsAndGetsTheParallaxOnTop() throws {
        session.applyDepthParallax(texture: texture, strength: 1, to: 10, actionName: "Apply")
        XCTAssertEqual(session.outline.layer(10)?.effects.map(\.key), ["0", "1", "+1"])
        let effects = try XCTUnwrap(try Fixtures.object(10, in: try applied())["effects"] as? [[String: Any]])
        XCTAssertEqual(effects.map { $0["file"] as? String }, ["effects/waterripple/effect.json", "effects/blur/effect.json",
                                                               SceneDepthParallax.effectFile])
    }

    func testApplyingAgainBindsTheNewDepthMapInOneStep() throws {
        session.applyDepthParallax(texture: texture, strength: 0.6, to: 13, actionName: "Apply")
        session.applyDepthParallax(texture: newer, strength: 0.6, to: 13, actionName: "Apply")
        XCTAssertEqual(session.outline.layer(13)?.effects.count, 1, "rebound, not added twice")
        XCTAssertEqual(session.depthParallaxTexture(of: 13), newer)
        session.undo()
        XCTAssertEqual(session.depthParallaxTexture(of: 13), texture)
    }

    func testANewGenerationRebindsAndKeepsTheStrength() throws {
        session.applyDepthParallax(texture: texture, strength: 0.4, to: 13, actionName: "Apply")
        session.setDepthParallaxStrength(1.5, of: 13, actionName: "Strength", coalescing: false)
        session.setDepthParallaxTexture(newer, of: 13, actionName: "Update")
        XCTAssertEqual(session.depthParallaxTexture(of: 13), newer)
        XCTAssertEqual(try XCTUnwrap(session.depthParallaxStrength(of: 13)), 1.5, accuracy: 1e-9)
    }

    func testStrengthIsUndoable() throws {
        session.applyDepthParallax(texture: texture, strength: 1, to: 13, actionName: "Apply")
        session.setDepthParallaxStrength(0.3, of: 13, actionName: "Strength", coalescing: false)
        XCTAssertEqual(try XCTUnwrap(session.depthParallaxStrength(of: 13)), 0.3, accuracy: 1e-9)
        let constants = firstPass(try XCTUnwrap(depthEffect(in: try Fixtures.object(13, in: try applied()))))["constantshadervalues"] as? [String: Any]
        XCTAssertEqual(SceneVector.components(SceneJSONValue(any: constants?["scale"])), [0.3, 0.3])
        session.undo()
        XCTAssertEqual(try XCTUnwrap(session.depthParallaxStrength(of: 13)), 1, accuracy: 1e-9)
    }

    func testRemoveTakesTheEffectAway() throws {
        session.applyDepthParallax(texture: texture, strength: 1, to: 13, actionName: "Apply")
        session.removeDepthParallax(of: 13, actionName: "Remove")
        XCTAssertNil(session.depthParallaxEffect(of: 13))
        XCTAssertNil(depthEffect(in: try Fixtures.object(13, in: try applied())))
        XCTAssertFalse(session.overlay.hasSceneEdits)
        session.undo()
        XCTAssertEqual(session.depthParallaxTexture(of: 13), texture)
    }

    func testAnEffectBoundToAnotherTextureIsntOurs() throws {
        let entry = EffectCatalogEntry(file: SceneDepthParallax.effectFile, title: "Depth Parallax")
        let key = try XCTUnwrap(session.addEffect(entry, to: 13, actionName: "Add"))
        session.setEffectTexture("masks/hand_painted", slot: 1, effect: key, of: 13, actionName: "Texture")
        XCTAssertNil(session.depthParallaxEffect(of: 13), "a depth map the author painted is left alone")
        session.applyDepthParallax(texture: texture, strength: 1, to: 13, actionName: "Apply")
        XCTAssertEqual(session.outline.layer(13)?.effects.count, 2)
    }

    func testPlacementByKind() throws {
        let outline = session.outline
        XCTAssertEqual(SceneDepthParallax.placement(for: try XCTUnwrap(outline.layer(10))), .onLayer)
        XCTAssertEqual(SceneDepthParallax.placement(for: try XCTUnwrap(outline.layer(11))), .onLayer, "text")
        XCTAssertEqual(SceneDepthParallax.placement(for: try XCTUnwrap(outline.layer(2))), .layerAbove, "particles")
    }

    func testTextSolidAndCompositionLayersTakeTheEffectOnThemselves() throws {
        let solid = session.addLayer(SceneLayerFactory.solid(name: "Fill", color: SIMD3(0.2, 0.4, 0.6), size: SIMD2(400, 300),
                                                             origin: SIMD2(400, 400)), actionName: "Add")
        let composition = session.addLayer(SceneLayerFactory.composition(name: "Comp", size: SIMD2(800, 600),
                                                                         origin: SIMD2(960, 540)), actionName: "Add")
        for id in [11, solid, composition] {
            session.applyDepthParallax(texture: texture, strength: 1, to: id, actionName: "Apply")
            XCTAssertEqual(session.depthParallaxTexture(of: id), texture, "layer \(id)")
            XCTAssertNotNil(depthEffect(in: try Fixtures.object(id, in: try applied())), "layer \(id)")
        }
    }

    // MARK: Above a particle system, and the scene

    func testAParticleSystemGetsAFullscreenLayerDirectlyAboveIt() throws {
        let sparks = 2
        let id = session.addDepthParallaxLayer(texture: texture, strength: 0.8, above: sparks, name: "Depth Parallax",
                                               actionName: "Apply")
        let order = session.outline.layers.map(\.id)
        XCTAssertEqual(order.firstIndex(of: id), try XCTUnwrap(order.firstIndex(of: sparks)) + 1)
        XCTAssertEqual(session.depthParallaxLayer(above: sparks), id)
        XCTAssertEqual(session.outline.layer(id)?.imageRole, .fullscreen)
        XCTAssertEqual(session.depthParallaxTexture(of: id), texture)
        let object = try Fixtures.object(id, in: try applied())
        XCTAssertEqual(object["image"] as? String, "models/util/fullscreenlayer.json")
        XCTAssertNotNil(depthEffect(in: object))
        XCTAssertNil(session.selection, "the selection stays")

        session.setDepthParallaxTexture(newer, of: id, actionName: "Update")
        XCTAssertEqual(session.depthParallaxTexture(of: id), newer)
        XCTAssertEqual(session.outline.layers.map(\.id), order, "rebinding keeps the draw order")

        session.delete([id], actionName: "Remove")
        XCTAssertNil(session.depthParallaxLayer(above: sparks))
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }

    func testTheSceneGetsAFullscreenLayerOnTop() throws {
        XCTAssertNil(session.depthParallaxLayer(above: nil))
        let id = session.addDepthParallaxLayer(texture: texture, strength: 1, above: nil, name: "Scene Depth Parallax",
                                               actionName: "Apply")
        XCTAssertEqual(session.outline.layers.last?.id, id)
        XCTAssertEqual(session.depthParallaxLayer(above: nil), id)
        session.setDepthParallaxStrength(0.5, of: id, actionName: "Strength", coalescing: false)
        let effect = try XCTUnwrap(depthEffect(in: try Fixtures.object(id, in: try applied())))
        let constants = firstPass(effect)["constantshadervalues"] as? [String: Any]
        XCTAssertEqual(SceneVector.components(SceneJSONValue(any: constants?["scale"])), [0.5, 0.5])
        session.undo()
        session.undo()
        XCTAssertNil(session.depthParallaxLayer(above: nil))
    }

    // MARK: Camera parallax

    private func general(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return root["general"] as? [String: Any] ?? [:]
    }

    /// `g_ParallaxPosition` moves only with `general.cameraparallax` on: the first depth parallax
    /// turns it on at amount 0 (the layers stay put), the last one's removal restores the scene's.
    func testDepthParallaxTurnsCameraParallaxOnWithoutMovingTheLayers() throws {
        session.applyDepthParallax(texture: texture, strength: 1, to: 13, actionName: "Apply")
        var settings = try general(try applied())
        XCTAssertEqual(settings["cameraparallax"] as? Bool, true)
        XCTAssertEqual(settings["cameraparallaxamount"] as? Double, 0)
        XCTAssertNil(settings["cameraparallaxdelay"], "the scene's own delay and influence stay")
        XCTAssertNil(settings["cameraparallaxmouseinfluence"])
        XCTAssertEqual(settings["clearcolor"] as? String, "0 0 0")
        XCTAssertEqual(try SceneEditOverlay.decoded(from: try session.overlay.encoded()), session.overlay)

        let id = session.addDepthParallaxLayer(texture: texture, strength: 1, above: nil, name: "Scene", actionName: "Apply")
        session.removeDepthParallax(of: 13, actionName: "Remove")
        XCTAssertEqual(try general(try applied())["cameraparallax"] as? Bool, true, "one is left")
        session.delete([id], actionName: "Remove")
        settings = try general(try applied())
        XCTAssertNil(settings["cameraparallax"])
        XCTAssertNil(settings["cameraparallaxamount"])
        XCTAssertNil(session.overlay.general)

        session.undo()
        XCTAssertEqual(session.overlay.generalSetting("cameraparallax"), .bool(true))
        session.undo()
        session.undo()
        session.undo()
        XCTAssertNil(session.overlay.general, "undone with the effect")
    }

    func testASceneWithCameraParallaxOnIsLeftAsItIs() throws {
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: Fixtures.sceneData) as? [String: Any])
        var settings = root["general"] as? [String: Any] ?? [:]
        settings["cameraparallax"] = true
        settings["cameraparallaxamount"] = 0.4
        root["general"] = settings
        let data = try JSONSerialization.data(withJSONObject: root)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: data))
        session.applyDepthParallax(texture: texture, strength: 1, to: 13, actionName: "Apply")
        XCTAssertNil(session.overlay.general)
        XCTAssertEqual(try general(try session.overlay.applied(to: data))["cameraparallaxamount"] as? Double, 0.4)
    }

    // MARK: The depth map's file

    func testDepthMapsAreKeptWithTheEditorsFiles() throws {
        let directory = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EditorAssetStore(directory: directory)
        let png = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let path = try store.saveDepthMap(png, title: "Logo")
        XCTAssertTrue(path.hasPrefix("depth/editor_logo-"))
        XCTAssertTrue(SceneDepthParallax.isGeneratedDepthMap(path))
        let url = try XCTUnwrap(store.depthMapURL(path))
        XCTAssertEqual(url.lastPathComponent, "\((path as NSString).lastPathComponent).png")
        XCTAssertEqual(try Data(contentsOf: url), png)
        XCTAssertEqual(try store.saveDepthMap(png, title: "Logo"), path, "named by content")
        XCTAssertTrue(store.assets().contains { $0.path == "materials/\(path).png" }, "Save as New Wallpaper copies it")
    }
}
