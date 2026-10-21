import SwiftUI
import XCTest
import OWEModelImport
@testable import OWEEditor
@testable import OWESceneEditing

/// Add Layer › Model with a model file (WE's Add Asset › Model): an FBX or OBJ imported into
/// the edits' files becomes a model layer, is listed among the picker's models as Imported, and a
/// dropped one lands at the drop point.
@MainActor
final class AddModelImportTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "AddModelImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func actions(scene: String) throws -> (LayerActions, SceneEditSession, EditorTools) {
        var services = WallpaperEditorServices(makeCanvas: { AnyView(EmptyView()) }, blendModeTitle: "", blendModes: [],
                                               effectHelp: { _ in "" }, suggestedNewTitle: "", saveAsNewWallpaper: { $0 })
        services.assetStore = EditorAssetStore(directory: directory.appending(path: "store"))
        services.models = { [EditorModelChoice(path: "models/own/own.mdl", isShared: false), EditorModelChoice(path: "models/we/we.mdl", isShared: true)] }
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Data(scene.utf8)), undoManager: UndoManager())
        let tools = EditorTools()
        return (LayerActions(session: session, services: services, tools: tools), session, tools)
    }

    func objFile() throws -> URL {
        let url = directory.appending(path: "panel.obj")
        try Data("v -1 0 0\nv 1 0 0\nv 1 1 0\nvt 0 0\nvt 1 0\nvt 1 1\nf 1/1 2/2 3/3\n".utf8).write(to: url)
        return url
    }

    func testAnImportedModelBecomesALayerAndAChoice() throws {
        let (actions, session, tools) = try actions(scene: #"{"general": {"orthogonalprojection": {"width": 1920, "height": 1080}}, "objects": []}"#)
        actions.importModels([try objFile()])
        XCTAssertNil(tools.problem)
        let layer = try XCTUnwrap(session.outline.layers.last)
        let model = try XCTUnwrap(session.value("model", of: layer.id)?.stringValue)
        XCTAssertTrue(model.hasPrefix("models/panel-") && model.hasSuffix("/panel.mdl"), model)
        XCTAssertEqual(session.value("name", of: layer.id)?.stringValue, "panel")
        XCTAssertEqual(SceneVector.components(session.value("origin", of: layer.id)), [960, 540, 0])
        XCTAssertEqual(actions.importedModels(), [model])
        XCTAssertEqual(actions.modelChoices().map(\.path), ["models/own/own.mdl", model, "models/we/we.mdl"])
    }

    func testADroppedModelLandsAtTheDropPoint() throws {
        let (actions, session, _) = try actions(scene: #"{"general": {"orthogonalprojection": {"width": 1920, "height": 1080}}, "objects": []}"#)
        actions.importDropped([try objFile()], at: SIMD2(100, 200))
        let layer = try XCTUnwrap(session.outline.layers.last)
        XCTAssertEqual(SceneVector.components(session.value("origin", of: layer.id)), [100, 200, 0])
    }

    func testAFileThatIsntAModelIsReported() throws {
        let (actions, session, tools) = try actions(scene: #"{"objects": []}"#)
        let broken = directory.appending(path: "broken.fbx")
        try Data("nothing".utf8).write(to: broken)
        actions.importModels([broken])
        XCTAssertNotNil(tools.problem)
        XCTAssertTrue(session.outline.layers.isEmpty)
    }

    func testThePickerListsImportedModelsApart() throws {
        let view = ModelPickerView(models: [EditorModelChoice(path: "models/a/a.mdl", isShared: false)], imported: ["models/a/a.mdl"],
                                   importFiles: {}) { _ in }
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 440)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
