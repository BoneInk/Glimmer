import SwiftUI
import XCTest
import OWESceneEditing
@testable import OWEEditor

/// The editor names a user property by its label, as the property panels show it: the app's
/// title (a WE localisation key translated, HTML dropped), else an editor-added property's own
/// label, else its key.
final class UserPropertyTitleTests: XCTestCase {
    private func services(_ choices: [EditorUserPropertyChoice]) -> WallpaperEditorServices {
        var services = WallpaperEditorServices(makeCanvas: { AnyView(EmptyView()) }, blendModeTitle: "", blendModes: [],
                                               effectHelp: { _ in "" }, suggestedNewTitle: "",
                                               saveAsNewWallpaper: { $0 })
        services.userPropertyChoices = { choices }
        return services
    }

    func testAPropertyIsNamedByItsLabel() {
        let services = services([EditorUserPropertyChoice(key: "clocklocation", title: "Clock Location", type: "combo")])
        XCTAssertEqual(services.userPropertyTitle("clocklocation"), "Clock Location")
        let added = [UserPropertyDraft(key: "glow", kind: .bool, text: "<b>Glow</b>")]
        XCTAssertEqual(services.userPropertyTitle("glow", properties: added), "Glow", "one the editor added")
        XCTAssertEqual(services.userPropertyTitle("missing", properties: added), "missing", "no label: the key")
    }

    /// The script and binding menu's help and its Unbind item name the property by its label.
    @MainActor
    func testTheScriptAndBindingMenuNamesThePropertyByItsLabel() throws {
        let scene = Data(#"{"general": {"orthogonalprojection": {"width": 100, "height": 100}}, "objects": [{"id": 2, "text": "12:00"}]}"#.utf8)
        let session = SceneEditSession(outline: try SceneOutline(sceneData: scene), undoManager: UndoManager())
        let authoring = EditorAuthoringModel(session: session, projectJSON: nil, console: nil,
                                             services: services([EditorUserPropertyChoice(key: "clocklocation",
                                                                                          title: "Clock Location", type: "combo")]))
        XCTAssertEqual(authoring.userPropertyTitle("clocklocation"), "Clock Location")
        XCTAssertEqual(authoring.userPropertyTitle("missing"), "missing")
        let bound = SceneFieldDrivers(user: SceneUserBinding(name: "clocklocation"))
        XCTAssertEqual(FieldAuthoringModifier.help(bound, propertyTitle: authoring.userPropertyTitle),
                       L("Set by the user property “\("Clock Location")”"))
        let scripted = SceneFieldDrivers(script: SceneScriptAttachment(source: "x"), user: SceneUserBinding(name: "clocklocation"))
        XCTAssertEqual(FieldAuthoringModifier.help(scripted, propertyTitle: authoring.userPropertyTitle),
                       L("A script and the user property “\("Clock Location")” set this field"))
        XCTAssertEqual(EditorAuthoringModel(session: session, projectJSON: nil, console: nil).userPropertyTitle("clocklocation"),
                       "clocklocation", "without the app's services: the key")
    }
}
