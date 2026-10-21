import Foundation
import OWEModelImport
@testable import OWESceneEditing
import XCTest

/// What the Model Editor edits: a model shader's annotations, a material's first pass, edited
/// materials compiled into the model, and the layers pointed at the recompiled model.
@MainActor
final class ModelEditingTests: XCTestCase {
    /// Lines as WE's `generic4` writes them (its annotations' form, not its code).
    static let shader = """
    // [COMBO] {"material":"ui_editor_properties_lighting","combo":"LIGHTING","default":1}
    // [COMBO] {"material":"ui_editor_properties_rim_lighting","combo":"RIMLIGHTING","default":0,"require":{"LIGHTING":1}}
    // [COMBO] {"material":"ui_editor_properties_fur_quality","combo":"INSTANCECOUNT","default":5,"options":{"ui_editor_properties_low":5,"ui_editor_properties_high":13}}
    uniform sampler2D g_Texture0; // {"material":"albedo","label":"ui_editor_properties_albedo","default":"util/white"}
    uniform sampler2D g_Texture1; // {"label":"ui_editor_properties_normal_map","format":"normalmap","formatcombo":true,"combo":"NORMALMAP"}
    uniform sampler2D g_Texture2; // {"combo":"PBRMASKS","components":[{"label":"ui_editor_properties_metallic_map","combo":"METALLIC_MAP"},{"label":"ui_editor_properties_roughness_map","combo":"ROUGHNESS_MAP"}]}
    uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
    uniform float g_Metallic; // {"material":"metallic","label":"ui_editor_properties_metallic","default":0,"range":[0,1],"group":"ui_editor_properties_material"}
    uniform vec3 g_EmissiveColor; // {"material":"emissivecolor", "label":"ui_editor_properties_emissive_color", "type": "color", "default":"1 0.5 0","group":"ui_editor_properties_material"}
    uniform mat4 g_ModelMatrix;
    """

    func testTheShaderAnnotationsGiveCombosTexturesAndConstants() throws {
        let schema = try XCTUnwrap(ModelShaderSchema.load("generic4") { path in
            path == "shaders/generic4.frag" ? Data(Self.shader.utf8) : nil
        })
        XCTAssertEqual(schema.combos.map(\.name), ["LIGHTING", "RIMLIGHTING", "INSTANCECOUNT"])
        XCTAssertEqual(schema.combos[0].defaultValue, 1)
        XCTAssertEqual(schema.combos[1].requirements, ["LIGHTING": 1])
        XCTAssertEqual(schema.combos[2].options.map(\.value), [5, 13])
        XCTAssertEqual(schema.textures.map(\.slot), [0, 1, 2])  // the hidden one left out
        XCTAssertEqual(schema.textures[1].combo, "NORMALMAP")
        XCTAssertEqual(schema.textures[2].components.map(\.combo), ["METALLIC_MAP", "ROUGHNESS_MAP"])
        XCTAssertEqual(schema.constants.map(\.key), ["metallic", "emissivecolor"])
        XCTAssertEqual(schema.constants[1].defaultValue, [1, 0.5, 0])
        XCTAssertTrue(schema.constants[1].isColor)
        XCTAssertEqual(schema.constants[0].group, "ui_editor_properties_material")
        XCTAssertFalse(ModelShaderSchema.holds(schema.combos[1].requirements) { _ in 0 })
        XCTAssertNil(ModelShaderSchema.load("generic4") { _ in nil })
    }

    func testAMaterialsPassIsEditedAndTheRestKept() throws {
        var document = MaterialPassDocument(root: ModelCompiler.materialJSON(texture: "models/a/Skin"))
        document.root["custom"] = .bool(true)
        XCTAssertEqual(document.shader, "generic4")
        document.shader = "fur4"
        document.setCombo("LIGHTING", 0)
        document.setTexture(2, "models/a/pbr")
        document.setConstant("metallic", [0.5])
        document.setConstant("emissivecolor", [1, 0, 0])
        let read = try XCTUnwrap(MaterialPassDocument(json: try document.jsonData()))
        XCTAssertEqual(read.shader, "fur4")
        XCTAssertEqual(read.combo("LIGHTING", default: 1), 0)
        XCTAssertEqual(read.combo("FOG", default: 1), 1)
        XCTAssertEqual(read.texture(0), "models/a/Skin")
        XCTAssertNil(read.texture(1))
        XCTAssertEqual(read.texture(2), "models/a/pbr")
        XCTAssertEqual(read.constant("metallic"), [0.5])
        XCTAssertEqual(read.constant("emissivecolor"), [1, 0, 0])
        XCTAssertEqual(read.root["custom"], .bool(true))
        var cleared = read
        cleared.setTexture(2, nil)
        XCTAssertEqual(cleared.texture(0), "models/a/Skin")
        if case .array(let textures)? = cleared.pass["textures"] { XCTAssertEqual(textures.count, 1) } else { XCTFail("no textures") }
    }

    func testAnEditedMaterialIsWhatTheModelNames() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ModelEditingTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appending(path: "skinned-quad.fbx")
        try FileManager.default.copyItem(at: try ModelImportTests.fixture("skinned-quad.fbx"), to: source)
        let store = EditorAssetStore(directory: directory.appending(path: "store"))
        let imported = try EditorModelImporter.importModel(from: source, into: store)
        let folder = EditorAssetStore.modelFolder(of: imported.model)
        XCTAssertEqual(EditorAssetStore.materialPath("Skin", model: imported.model, config: ModelImportConfig()),
                       "materials/models/\(folder)/Skin.json")
        var document = MaterialPassDocument(root: ModelCompiler.materialJSON(texture: nil))
        document.setCombo("RIMLIGHTING", 1)
        let edited = try store.storeModelMaterial(document, material: "Skin", model: imported.model)
        XCTAssertTrue(edited.hasPrefix("materials/models/\(folder)/Skin-"))
        var config = ModelImportConfig()
        config.materials["Skin"] = edited
        XCTAssertEqual(try ModelImportConfig(json: try config.jsonData()).materials, ["Skin": edited])
        let recompiled = try EditorModelImporter.recompile(imported.model, config: config, in: store)
        let model = try MDLTestReader.read(try Data(contentsOf: try XCTUnwrap(store.url(for: recompiled.model))))
        XCTAssertEqual(model.meshes.first?.materials, [edited])
        let texture = directory.appending(path: "pbr.png")
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!.write(to: texture)
        let path = try store.importModelTexture(from: texture, material: "Skin", slot: 2, model: imported.model)
        XCTAssertTrue(path.hasPrefix("models/\(folder)/Skin_2-"))
        XCTAssertNotNil(store.url(for: "materials/\(path).png"))
    }

    func testLayersDrawingAModelArePointedAtTheNewOneInOneStep() throws {
        let scene = Data(#"{"objects": [{"id": 1, "name": "a", "model": "models/x/x.mdl"}, {"id": 2, "name": "b", "model": "models/x/x.mdl"}, {"id": 3, "name": "c", "model": "models/y/y.mdl"}]}"#.utf8)
        let undo = UndoManager()
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: undo)
        XCTAssertEqual(session.layers(drawing: "models/x/x.mdl"), [1, 2])
        session.replaceModel("models/x/x.mdl", with: "models/x/x-1234.mdl", actionName: "Configure Model")
        XCTAssertEqual(session.layers(drawing: "models/x/x-1234.mdl"), [1, 2])
        XCTAssertEqual(session.value("model", of: 3)?.stringValue, "models/y/y.mdl")
        undo.undo()
        XCTAssertEqual(session.layers(drawing: "models/x/x.mdl"), [1, 2])
        // Back to the authored model: no edit is left.
        session.replaceModel("models/x/x.mdl", with: "models/x/x-1234.mdl", actionName: "Configure Model")
        session.replaceModel("models/x/x-1234.mdl", with: "models/x/x.mdl", actionName: "Configure Model")
        XCTAssertFalse(session.overlay.hasSceneEdits)
    }
}
