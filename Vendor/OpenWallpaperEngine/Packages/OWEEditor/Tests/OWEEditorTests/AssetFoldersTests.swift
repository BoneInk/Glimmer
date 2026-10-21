import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// WE's asset folders in the browser, and what Edit with External Image Editor edits.
@MainActor
final class AssetFoldersTests: XCTestCase {
    func testFilesSortIntoWEsFolders() {
        XCTAssertEqual(EditorAsset.kind(of: "materials/glass.json"), .material)
        XCTAssertEqual(EditorAsset.kind(of: "materials/glass.tex"), .texture)
        XCTAssertEqual(EditorAsset.kind(of: "models/tree.json"), .model)
        XCTAssertEqual(EditorAsset.kind(of: "particles/rain.json"), .particle)
        XCTAssertEqual(EditorAsset.kind(of: "sounds/rain.mp3"), .sound)
        XCTAssertEqual(EditorAsset.kind(of: "scene.json"), .other)
        XCTAssertEqual(EditorAsset.Kind.material.title, "Materials")
        XCTAssertEqual(EditorAsset.Kind.particle.title, "Particles")
    }

    func testTheExternalEditorEditsTheLayersOwnTexture() throws {
        let scene = Data(#"""
        {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
         "objects": [{"id": 1, "image": "models/logo.json"}, {"id": 2, "image": "models/util/solidlayer.json"}]}
        """#.utf8)
        let outline = try SceneOutline(sceneData: scene)
        let files: [String: String] = [
            "models/logo.json": #"{"material": "materials/logo.json"}"#,
            "materials/logo.json": #"{"passes": [{"textures": ["logo", "logo_normal"]}]}"#,
        ]
        let read: (String) -> Data? = { files[$0].map { Data($0.utf8) } }
        XCTAssertEqual(ExternalImageEditor.texture(of: try XCTUnwrap(outline.layer(1)), readFile: read), "logo")
        XCTAssertNil(ExternalImageEditor.texture(of: try XCTUnwrap(outline.layer(2)), readFile: read), "a solid has no picture")
    }
}
