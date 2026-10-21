import XCTest
@testable import OWESceneEditing

/// WE 2.8.0.42 capture 541: Albedo › Bind User Property › Add Property (Texture, "Custom texture")
/// on an editor-imported image layer. WE wrote the property into project.json as
/// `{"index": 1, "order": 101, "text": "Custom texture", "type": "scenetexture", "value": ""}` (after a
/// combo at index 0, order 100) and the link into the layer's material, `materials/variant_a.json`'s
/// first pass: `"usertextures": ["customtexture"]` beside `"textures": ["variant_a"]`. The scene
/// object was left as it was.
@MainActor
final class UserTextureCapture541Tests: XCTestCase {
    static let scene = Data("""
    {"objects": [
      {"id": 10, "name": "bars", "image": "models/bars.json", "size": "512.00000 256.00000"},
      {"id": 22, "name": "variant_a", "image": "models/variant_a.json", "size": "512.00000 256.00000"}]}
    """.utf8)
    static let project = Data("""
    {"file": "scene.json", "title": "p540_var", "type": "scene", "general": {"properties": {
      "schemecolor": {"order": 0, "text": "ui_browse_properties_scheme_color", "type": "color", "value": "0 0 0"},
      "shapesel": {"index": 0, "order": 100, "text": "Shape variant", "type": "combo", "value": "0",
                   "options": [{"label": "base", "value": "0"}, {"label": "b replace", "value": "1"}]}}}}
    """.utf8)
    /// The material before the binding (the capture's `variant_a_material.json` without it).
    static let material = """
    {"passes": [{"alphawriting": "default", "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled",
      "depthwrite": "disabled", "shader": "genericimage4", "textures": ["variant_a"]}]}
    """
    static let files: [String: String] = [
        "models/bars.json": #"{"material": "materials/bars.json"}"#,
        "materials/bars.json": #"{"passes": [{"shader": "genericimage2", "textures": ["bars"]}]}"#,
        "models/variant_a.json": #"{"material": "materials/variant_a.json"}"#,
        "materials/variant_a.json": material,
    ]

    private var session: SceneEditSession!
    private var authoring: UserPropertyAuthoring!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Self.scene), undoManager: undoManager)
        session.coalescingInterval = 0
        authoring = UserPropertyAuthoring(session: session, projectJSON: Self.project,
                                          readAsset: { Self.files[$0].map { Data($0.utf8) } })
    }

    private func pass(_ path: String) throws -> [String: Any] {
        let document = try XCTUnwrap(session.overlay.document(path), "the material is edited")
        let passes = try XCTUnwrap((document.any as? [String: Any])?["passes"] as? [[String: Any]])
        return try XCTUnwrap(passes.first)
    }

    func testBindingWritesTheMaterialPassAsWEDoes() throws {
        XCTAssertEqual(authoring.add(.sceneTexture, label: "Custom texture", actionName: "Add"), "customtexture")
        authoring.bindTexture(UserTextureBinding(layer: 22), to: "customtexture", actionName: "Bind")
        let first = try pass("materials/variant_a.json")
        XCTAssertEqual(first["usertextures"] as? [String], ["customtexture"])
        XCTAssertEqual(first["textures"] as? [String], ["variant_a"])
        XCTAssertEqual(first["shader"] as? String, "genericimage4")
        XCTAssertNil(session.overlay.field("instance", of: 22), "the scene object is unchanged")
        XCTAssertEqual(authoring.textureBindings(of: "customtexture"), [UserTextureBinding(layer: 22)])

        // project.json: WE's numbering.
        let written = try XCTUnwrap(session.overlay.authoring).appliedProject(to: Self.project)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let entries = try XCTUnwrap((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])
        let texture = try XCTUnwrap(entries["customtexture"])
        XCTAssertEqual(texture["type"] as? String, "scenetexture")
        XCTAssertEqual(texture["text"] as? String, "Custom texture")
        XCTAssertEqual(texture["value"] as? String, "")
        XCTAssertEqual((texture["index"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual((texture["order"] as? NSNumber)?.intValue, 101)
        XCTAssertEqual((entries["shapesel"]?["order"] as? NSNumber)?.intValue, 100)
        XCTAssertEqual((entries["schemecolor"]?["order"] as? NSNumber)?.intValue, 0)
        XCTAssertNil(entries["schemecolor"]?["index"])

        // Any slot: the normal map's, beside the albedo's.
        authoring.bindTexture(UserTextureBinding(layer: 22, slot: 2), to: "customtexture", actionName: "Bind")
        XCTAssertEqual(try pass("materials/variant_a.json")["usertextures"] as? [NSObject],
                       ["customtexture" as NSString, NSNull(), "customtexture" as NSString])
        XCTAssertEqual(authoring.textureBindings(of: "customtexture"),
                       [UserTextureBinding(layer: 22), UserTextureBinding(layer: 22, slot: 2)])

        // A rename re-points the material's links; unbinding drops them, back to the file.
        XCTAssertTrue(authoring.rename("customtexture", to: "wall", actionName: "Rename"))
        XCTAssertEqual(try pass("materials/variant_a.json")["usertextures"] as? [NSObject],
                       ["wall" as NSString, NSNull(), "wall" as NSString])
        authoring.unbindTexture(UserTextureBinding(layer: 22, slot: 2), actionName: "Unbind")
        authoring.unbindTexture(UserTextureBinding(layer: 22), actionName: "Unbind")
        XCTAssertNil(session.overlay.document("materials/variant_a.json"), "no edit left")
        XCTAssertTrue(authoring.textureBindings(of: "wall").isEmpty)
    }

    /// A draft saved with the instance form still reads, and binding again moves it to the material.
    func testTheOldInstanceFormStillReads() throws {
        authoring.add(.sceneTexture, label: "Custom texture", actionName: "Add")
        session.editOverlay(actionName: "Old") { overlay in
            overlay.setField("instance", to: .object(["usertextures": .array([.string("customtexture")])]), of: 22)
        }
        XCTAssertEqual(authoring.textureProperty(of: UserTextureBinding(layer: 22)), "customtexture")
        authoring.bindTexture(UserTextureBinding(layer: 22), to: "customtexture", actionName: "Bind")
        XCTAssertNil(session.overlay.field("instance", of: 22))
        XCTAssertEqual(try pass("materials/variant_a.json")["usertextures"] as? [String], ["customtexture"])
    }
}
