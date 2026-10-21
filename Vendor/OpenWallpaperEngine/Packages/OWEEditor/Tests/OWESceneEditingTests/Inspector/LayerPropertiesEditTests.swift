import XCTest
@testable import OWESceneEditing

/// The image layer fields of WE's inspector through the overlay: plain fields (parallax depth,
/// perspective, click events, propagation, copy background, alignment, brightness, Clamp UVs)
/// and Lighting & Reflections, which edits the material the layer's model names: kept in the
/// overlay's documents, read by the scene in place of the file, one undo step each, reloading the
/// scene, and written into a saved copy.
@MainActor
final class LayerPropertiesEditTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "cameraparallax": true},
     "objects": [{"id": 1, "name": "Sword", "image": "models/sword.json", "size": "400 800", "origin": "960 540 0"},
                 {"id": 2, "name": "Glass", "image": "models/util/composelayer.json", "size": "400 400", "origin": "500 500 0"}]}
    """
    private static let material = """
    {"passes": [{"blending": "translucent", "shader": "genericimage4", "textures": ["sword"],
                 "combos": {"LIGHTING": 0}, "constantshadervalues": {"roughness": 0.55}}]}
    """
    private static let files: [String: Data] = [
        "models/sword.json": Data(#"{"autosize": true, "material": "materials/sword.json"}"#.utf8),
        "materials/sword.json": Data(material.utf8),
    ]
    private var session: SceneEditSession!
    private var sceneData: Data { Data(Self.sceneJSON.utf8) }
    private let read: (String) -> Data? = { LayerPropertiesEditTests.files[$0] }

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData), undoManager: undoManager)
    }

    private func object(_ id: Int) throws -> [String: Any] {
        try Fixtures.object(id, in: try session.overlay.applied(to: sceneData))
    }

    func testTheLayerFieldsReachTheScene() throws {
        session.setValue(.string("0.5 2"), for: "parallaxDepth", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "perspective", of: 1, actionName: "Change")
        session.setValue(.bool(false), for: "solid", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "disablepropagation", of: 1, actionName: "Change")
        session.setValue(.string("topleft"), for: "alignment", of: 1, actionName: "Change")
        session.setValue(.number(1.5), for: "brightness", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "clampuvs", of: 1, actionName: "Change")
        session.setValue(.bool(false), for: "copybackground", of: 2, actionName: "Change")
        let sword = try object(1)
        XCTAssertEqual(sword["parallaxDepth"] as? String, "0.5 2")
        XCTAssertEqual(sword["perspective"] as? Bool, true)
        XCTAssertEqual(sword["solid"] as? Bool, false)
        XCTAssertEqual(sword["disablepropagation"] as? Bool, true)
        XCTAssertEqual(sword["alignment"] as? String, "topleft")
        XCTAssertEqual(sword["brightness"] as? Double, 1.5)
        XCTAssertEqual(sword["clampuvs"] as? Bool, true)
        XCTAssertEqual(try object(2)["copybackground"] as? Bool, false)
    }

    func testWEsDefaultsAreNoEdit() {
        for (field, value) in [("brightness", SceneJSONValue.number(1)), ("perspective", .bool(false)),
                               ("copybackground", .bool(true)), ("disablepropagation", .bool(false)),
                               ("clampuvs", .bool(false)), ("alignment", .string("center")), ("parallaxDepth", .string("1 1")),
                               ("solid", .bool(true))] {
            session.setValue(value, for: field, of: 1, actionName: "Change")
        }
        XCTAssertTrue(session.overlay.isEmpty, "\(session.overlay.objects)")
    }

    // MARK: Lighting & Reflections

    func testTheMaterialIsTheModelsAndLightable() throws {
        let material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        XCTAssertEqual(material.path, "materials/sword.json")
        XCTAssertTrue(material.isLightable)
        XCTAssertFalse(material.lighting)
        XCTAssertNil(material.normalMap)
        let roughness = try XCTUnwrap(ImageLayerLighting.constants(shader: material.shader).first { $0.key == "roughness" })
        XCTAssertEqual(material.constant(roughness), [0.55])
        let metallic = try XCTUnwrap(ImageLayerLighting.constants(shader: material.shader).first { $0.key == "metallic" })
        XCTAssertEqual(material.constant(metallic), [0], "genericimage4's default")
        XCTAssertNil(session.imageMaterial(of: 2, readAsset: read), "a composition layer has no material of its own")
    }

    func testLightingEditsTheMaterialDocument() throws {
        var material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingCombo("LIGHTING", to: 1), path: material.path, readAsset: read, actionName: "Lighting")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingNormalMap("sword_normal"), path: material.path, readAsset: read, actionName: "Normal")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingConstant("emissivecolor", to: [1, 0.5, 0]), path: material.path, readAsset: read,
                                 actionName: "Emissive")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        XCTAssertTrue(material.lighting)
        XCTAssertEqual(material.normalMap, "sword_normal")

        let data = try XCTUnwrap(session.overlay.editorFileData()["materials/sword.json"])
        let pass = try XCTUnwrap(((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["passes"] as? [[String: Any]])?.first)
        XCTAssertEqual((pass["combos"] as? [String: Any])?["LIGHTING"] as? Int, 1)
        XCTAssertEqual(pass["textures"] as? [String], ["sword", "sword_normal"])
        let constants = try XCTUnwrap(pass["constantshadervalues"] as? [String: Any])
        XCTAssertEqual(constants["emissivecolor"] as? String, "1 0.5 0")
        XCTAssertEqual(constants["roughness"] as? Double, 0.55, "other constants stay")
        XCTAssertEqual(pass["shader"] as? String, "genericimage4")

        XCTAssertNotNil(try session.overlay.editorFiles()["materials/sword.json"], "Save as New writes it")
        XCTAssertEqual(session.overlay.liveChange(from: SceneEditOverlay()), .scene, "the scene is read again")

        session.undo()
        session.undo()
        session.undo()
        XCTAssertNil(session.overlay.documents, "one undo step each")
    }

    func testTurningEverythingBackDropsTheDocument() throws {
        var material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingCombo("REFLECTION", to: 1), path: material.path, readAsset: read, actionName: "On")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingCombo("REFLECTION", to: 0), path: material.path, readAsset: read, actionName: "Off")
        XCTAssertNil(session.overlay.documents, "the wallpaper's material again")
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testDocumentsRoundTripAndChangeTheDigest() throws {
        let digest = session.overlay.digest
        let material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingCombo("LIGHTING", to: 1), path: material.path, readAsset: read, actionName: "On")
        XCTAssertNotEqual(session.overlay.digest, digest, "a scene read with the edited material isn't reused")
        let decoded = try SceneEditOverlay.decoded(from: try session.overlay.encoded())
        XCTAssertEqual(decoded.documents, session.overlay.documents)
        XCTAssertNil(SceneEditLiveValues.make(built: SceneEditOverlay(), current: session.overlay, base: session.baseOutline),
                     "not drawn live: the scene is read again")
    }
}
