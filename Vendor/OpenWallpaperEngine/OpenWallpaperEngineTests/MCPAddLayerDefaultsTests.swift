import XCTest
import OWEControlProtocol
import OWESceneEditing
@testable import OpenWallpaperEngine

/// `add_layer`'s defaults: the scene as the renderer draws it (`SceneContentLoader.sceneSize(of:)`),
/// an image model's own size, and WE's new text layer at 32 points.
@MainActor
final class MCPAddLayerDefaultsTests: XCTestCase {
    private func scene(_ general: String, objects: String = "[]") -> Data {
        Data(#"{"camera": {}, "general": \#(general), "objects": \#(objects)}"#.utf8)
    }

    func testCanvasIsTheRenderersSceneSize() throws {
        let ortho = try SceneAddLayerDefaults.canvas(sceneData: scene(#"{"orthogonalprojection": {"width": 2560, "height": 1440}}"#),
                                                     overlay: SceneEditOverlay())
        XCTAssertEqual(ortho.size, SIMD2(2560, 1440))
        XCTAssertEqual(ortho.centre, SIMD2(1280, 720))
        // `auto`: the first image object's size; without one, WE's 1920×1080 canvas.
        let auto = try SceneAddLayerDefaults.canvas(
            sceneData: scene(#"{"orthogonalprojection": {"auto": true}}"#,
                             objects: #"[{"id": 1, "image": "models/a.json", "size": "800 600"}]"#),
            overlay: SceneEditOverlay())
        XCTAssertEqual(auto.size, SIMD2(800, 600))
        let empty = try SceneAddLayerDefaults.canvas(sceneData: scene(#"{"orthogonalprojection": {"auto": true}}"#),
                                                     overlay: SceneEditOverlay())
        XCTAssertEqual(empty.size, SIMD2(1920, 1080))
        XCTAssertEqual(empty.centre, SIMD2(960, 540))
        // A 3D scene: the renderer's canvas, new layers at the origin as the editor puts them.
        let perspective = try SceneAddLayerDefaults.canvas(sceneData: scene("{}"), overlay: SceneEditOverlay())
        XCTAssertEqual(perspective.size, SIMD2(1920, 1080))
        XCTAssertEqual(perspective.centre, .zero)
    }

    func testAModelsImageSizeIsItsOwn() {
        let files = ["models/sized.json": Data(#"{"material": "materials/a.json", "width": 300, "height": 150}"#.utf8),
                     "models/bare.json": Data(#"{"material": "materials/missing.json"}"#.utf8)]
        XCTAssertEqual(SceneAddLayerDefaults.imageSize(ofModel: "models/sized.json", readAsset: { files[$0] }), SIMD2(300, 150))
        XCTAssertNil(SceneAddLayerDefaults.imageSize(ofModel: "models/bare.json", readAsset: { files[$0] }),
                     "nothing to measure: the caller's default")
        XCTAssertNil(SceneAddLayerDefaults.imageSize(ofModel: "models/none.json", readAsset: { files[$0] }))
    }

    func testANewTextLayerIsWEsThirtyTwoPoints() throws {
        let fixture = try MCPSceneFixture()
        defer { fixture.remove() }
        let document = try fixture.service().document(for: fixture.wallpaper)
        _ = try document.apply([ControlParameters(["op": "add_layer", "kind": "text", "text": "Hi"])], actionName: nil)
        let added = try XCTUnwrap(document.session.outline.layers.first { $0.name == "Hi" })
        XCTAssertEqual(added.fields["pointsize"]?.doubleValue, 32)
        XCTAssertEqual(Array(SceneVector.components(SceneFieldBinding.literal(of: added.fields["origin"])).prefix(2)), [960, 540])
    }
}
