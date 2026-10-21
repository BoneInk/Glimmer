import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The editor window's authoring state: the script editor's draft and Apply, script properties,
/// and which property kinds a field binds to.
@MainActor
final class EditorAuthoringModelTests: XCTestCase {
    private static let scene = Data("""
    {"general": {"orthogonalprojection": {"width": 100, "height": 100}},
     "objects": [{"id": 1, "image": "a.json", "alpha": 1, "effects": [{"file": "effects/blur/effect.json"}]},
                 {"id": 2, "name": "Clock", "text": "12:00"}]}
    """.utf8)

    private func model() throws -> EditorAuthoringModel {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Self.scene), undoManager: undoManager)
        let project = Data(#"{"general": {"properties": {"on": {"type": "bool", "value": true, "text": "On"}}}}"#.utf8)
        return EditorAuthoringModel(session: session, projectJSON: project, console: SceneScriptConsoleFeed(wallpaperID: "wp"))
    }

    func testANewScriptStartsFromItsFieldsTemplateAndApplyAttachesIt() throws {
        let model = try model()
        let target = FieldTarget(layer: 2, path: "text")
        model.editScript(target, template: .clockText)
        let draft = try XCTUnwrap(model.draft)
        XCTAssertEqual(draft.text, SceneScriptTemplate.template(.clockText).source)
        XCTAssertTrue(draft.isDirty)
        XCTAssertTrue(draft.syntax.isEmpty)

        model.applyScript()
        XCTAssertEqual(model.session.drivers("text", of: 2).script?.source, draft.text)
        XCTAssertFalse(try XCTUnwrap(model.draft).isDirty)
        XCTAssertNotNil(model.draft?.appliedAt)
        XCTAssertEqual(model.session.undoManager.undoActionName, L("Add Script"))

        model.setScriptProperty("use24h", to: .bool(false), on: target)
        XCTAssertEqual(model.session.drivers("text", of: 2).script?.scriptProperties?["use24h"], .bool(false))

        // Editing and applying again replaces it; values of properties the script still declares stay.
        model.setDraftText(draft.text + "\n// edited\n")
        model.applyScript()
        XCTAssertEqual(model.session.drivers("text", of: 2).script?.scriptProperties?["use24h"], .bool(false))
        model.setDraftText("export function update(value) { return value; }\n")
        model.applyScript()
        XCTAssertNil(model.session.drivers("text", of: 2).script?.scriptProperties?["use24h"],
                     "a property the script no longer declares is dropped")
    }

    func testTheObjectScriptAndSyntaxErrors() throws {
        let model = try model()
        model.editScript(FieldTarget(layer: 1, path: .objectScript))
        XCTAssertEqual(model.draft?.text, SceneScriptTemplate.template(.objectScript).source)
        model.setDraftText("export function update(value) {\n\treturn value +;\n}\n")
        model.useTemplate(.empty)
        XCTAssertTrue(model.diagnostics.isEmpty)
        model.setDraftText("export function update(value) {\n\treturn value +;\n}\n")
        model.applyScript()
        XCTAssertEqual(model.diagnostics.first?.line, 2)
        XCTAssertNil(model.session.drivers(.objectScript, of: 1).script, "a script with a syntax error isn't applied")
    }

    func testRemovingAScriptClosesItsEditor() throws {
        let model = try model()
        let target = FieldTarget(layer: 1, path: "alpha")
        model.editScript(target)
        model.applyScript()
        XCTAssertEqual(model.session.scriptedFields(of: 1), ["alpha"])
        model.removeScript(target)
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.session.scriptedFields(of: 1).isEmpty)
    }

    func testFieldsAndTheirPropertyKinds() throws {
        let model = try model()
        let image = try XCTUnwrap(model.session.outline.layer(1))
        let text = try XCTUnwrap(model.session.outline.layer(2))
        XCTAssertEqual(model.scriptableFields(of: image).map(\.description),
                       ["visible", "origin", "scale", "angles", "alpha", "color", "effects.0.visible"])
        XCTAssertTrue(model.scriptableFields(of: text).contains("text"))
        XCTAssertEqual(EditorAuthoringModel.propertyKind(for: "alpha"), .slider)
        XCTAssertEqual(EditorAuthoringModel.propertyKind(for: "visible"), .bool)
        XCTAssertEqual(EditorAuthoringModel.propertyKind(for: "color"), .color)
        XCTAssertEqual(EditorAuthoringModel.propertyKind(for: "text"), .textInput)
        XCTAssertEqual(EditorAuthoringModel.propertyKind(for: .effect(0)), .bool)
        XCTAssertNil(EditorAuthoringModel.propertyKind(for: "origin"))
        XCTAssertEqual(model.title(of: FieldTarget(layer: 2, path: "text")), "Clock › \(L("Text"))")
        XCTAssertEqual(model.properties.properties.map(\.key), ["on"])
    }
}
