import XCTest
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's image layer fields reach the player: the fields the session writes
/// into the overlay are what the scene's object decodes, and the material Lighting & Reflections
/// writes is a document the scene's build reads in place of the file (`editorFileData`,
/// `SceneContentLoader.setEditorAssets`), as the player's material type.
@MainActor
final class WallpaperEditorLayerFieldsTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "cameraparallax": true},
     "objects": [{"id": 1, "name": "Sword", "image": "models/sword.json", "size": "400 800", "origin": "960 540 0"}]}
    """
    private static let files: [String: Data] = [
        "models/sword.json": Data(#"{"material": "materials/sword.json"}"#.utf8),
        "materials/sword.json": Data(#"{"passes": [{"shader": "genericimage4", "textures": ["sword"]}]}"#.utf8),
    ]

    func testTheLayerFieldsAreWhatThePlayerReads() throws {
        let data = Data(Self.sceneJSON.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: data))
        session.setValue(.string("0.5 2"), for: "parallaxDepth", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "perspective", of: 1, actionName: "Change")
        session.setValue(.bool(false), for: "solid", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "disablepropagation", of: 1, actionName: "Change")
        session.setValue(.string("bottomright"), for: "alignment", of: 1, actionName: "Change")
        session.setValue(.number(1.5), for: "brightness", of: 1, actionName: "Change")
        session.setValue(.bool(true), for: "clampuvs", of: 1, actionName: "Change")

        let scene = try JSONDecoder().decode(WEScene.self, from: try session.overlay.applied(to: data))
        let object = try XCTUnwrap(scene.objects.first)
        XCTAssertEqual(object.parallaxDepthValue.0, 0.5)
        XCTAssertEqual(object.parallaxDepthValue.1, 2)
        XCTAssertEqual(object.perspective, true)
        XCTAssertEqual(object.solid, false)
        XCTAssertEqual(object.disablepropagation, true)
        XCTAssertEqual(object.alignment, "bottomright")
        XCTAssertEqual(object.brightness, 1.5)
        XCTAssertEqual(object.clampuvs, true)
    }

    func testTheLitMaterialIsWhatTheBuildReads() throws {
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Data(Self.sceneJSON.utf8)))
        let read: (String) -> Data? = { Self.files[$0] }
        var material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingCombo("LIGHTING", to: 1), path: material.path, readAsset: read, actionName: "On")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingNormalMap("sword_normal"), path: material.path, readAsset: read, actionName: "Map")
        material = try XCTUnwrap(session.imageMaterial(of: 1, readAsset: read))
        session.setImageMaterial(material.settingConstant("metallic", to: [0.8]), path: material.path, readAsset: read,
                                 actionName: "Metallic")

        let document = try XCTUnwrap(session.overlay.editorFileData()["materials/sword.json"])
        let pass = try XCTUnwrap(try JSONDecoder().decode(MaterialDocument.self, from: document).passes.first)
        XCTAssertEqual(pass.shader, "genericimage4")
        XCTAssertEqual(pass.combos["LIGHTING"], 1)
        XCTAssertEqual(pass.textures, ["sword", "sword_normal"])
        XCTAssertEqual(pass.constantshadervalues["metallic"], .number(0.8))
    }
}
