import XCTest
@testable import OWESceneEditing

/// The user-property editor's model: add, edit, remove, reorder and rename properties of every
/// type, their conditions, and the round trip through the overlay into project.json and back.
@MainActor
final class UserPropertyAuthoringTests: XCTestCase {
    static let projectJSON = Data("""
    {
      "file": "scene.json", "title": "Rain", "type": "scene", "workshopid": "42",
      "general": {"properties": {
        "schemecolor": {"order": 0, "text": "ui_browse_properties_scheme_color", "type": "color", "value": "0.1 0.2 0.3"},
        "showlogo": {"order": 1, "text": "Show logo", "type": "bool", "value": true},
        "speed": {"order": 2, "text": "Speed", "type": "slider", "value": 0.5, "min": 0, "max": 2, "step": 0.1,
                  "precision": 2, "fraction": true, "editable": true},
        "style": {"order": 3, "text": "Style", "type": "combo", "value": "a",
                  "options": [{"label": "A", "value": "a"}, {"label": "B", "value": "b"}]},
        "blurstrength": {"order": 4, "text": "Blur strength", "type": "slider", "value": 3, "min": 0, "max": 10,
                         "condition": "showblur.value == true"},
        "showblur": {"order": 5, "text": "Blur", "type": "bool", "value": false},
        "folder": {"order": 6, "text": "Pictures", "type": "directory", "value": "", "mode": "fetch"}
      }}
    }
    """.utf8)

    private var session: SceneEditSession!
    private var authoring: UserPropertyAuthoring!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        session.coalescingInterval = 0
        authoring = UserPropertyAuthoring(session: session, projectJSON: Self.projectJSON)
    }

    // MARK: Reading

    func testPropertiesAreReadInWEsOrderWithEveryField() throws {
        XCTAssertEqual(authoring.properties.map(\.key),
                       ["schemecolor", "showlogo", "speed", "style", "blurstrength", "showblur", "folder"])
        let speed = try XCTUnwrap(authoring.property("speed"))
        XCTAssertEqual(speed.kind, .slider)
        XCTAssertEqual(speed.minimum, 0)
        XCTAssertEqual(speed.maximum, 2)
        XCTAssertEqual(speed.step, 0.1)
        XCTAssertEqual(speed.decimals, 1, "WE stores one more than the decimals shown")
        XCTAssertEqual(speed.extra["editable"], .bool(true), "keys the editor doesn't model are kept")
        XCTAssertEqual(authoring.property("style")?.options.map(\.value), ["a", "b"])
        XCTAssertEqual(authoring.property("blurstrength")?.condition, "showblur.value == true")
        XCTAssertEqual(authoring.property("folder")?.extra["mode"], .string("fetch"))
        XCTAssertFalse(authoring.isEdited)
    }

    // MARK: CRUD with undo

    func testAddEveryTypeUndoAndRedo() {
        for kind in UserPropertyDraft.Kind.authorable {
            authoring.add(kind, label: "New \(kind.rawValue)", actionName: "Add")
        }
        let added = authoring.properties.suffix(UserPropertyDraft.Kind.authorable.count)
        XCTAssertEqual(added.map(\.kind), UserPropertyDraft.Kind.authorable)
        XCTAssertEqual(added.first?.key, "newbool")
        XCTAssertEqual(authoring.property("newslider")?.value, .number(0.5))
        XCTAssertEqual(authoring.property("newcombo")?.options.count, 2)
        XCTAssertNil(authoring.property("newtext")?.value, "a label has no value")
        XCTAssertTrue(authoring.isEdited)
        XCTAssertEqual(session.overlay.authoring?.properties?.count, 7 + UserPropertyDraft.Kind.authorable.count)

        for _ in UserPropertyDraft.Kind.authorable { session.undo() }
        XCTAssertFalse(authoring.isEdited, "undone back to project.json's own list")
        XCTAssertNil(session.overlay.authoring, "nothing left in the overlay")
        session.redo()
        XCTAssertEqual(authoring.properties.last?.key, "newbool")
    }

    func testUniqueKeysFromLabels() {
        // WE's dialog: lower case, every non-word character dropped.
        XCTAssertEqual(UserPropertyDraft.key(from: "Show Clock!", taken: []), "showclock")
        XCTAssertEqual(UserPropertyDraft.key(from: "Speed", taken: ["speed", "speed2"]), "speed3")
        XCTAssertEqual(UserPropertyDraft.key(from: "2 suns", taken: []), "_2suns")
        XCTAssertEqual(UserPropertyDraft.key(from: "Opacité du logo", taken: []), "opacitdulogo")
        XCTAssertEqual(UserPropertyDraft.key(from: "My_value", taken: []), "my_value")
        XCTAssertEqual(UserPropertyDraft.key(from: "!!!", taken: []), "newproperty")
        XCTAssertTrue(UserPropertyDraft.isValidKey("blur_2"))
        XCTAssertFalse(UserPropertyDraft.isValidKey("2blur"))
        XCTAssertFalse(UserPropertyDraft.isValidKey("blur strength"))
    }

    func testEditCoalescesTypingIntoOneStep() {
        session.coalescingInterval = 60
        authoring.update("speed", actionName: "Change Label") { $0.text = "S" }
        authoring.update("speed", actionName: "Change Label") { $0.text = "Sp" }
        authoring.update("speed", actionName: "Change Label") { $0.text = "Speed of rain" }
        XCTAssertEqual(authoring.property("speed")?.text, "Speed of rain")
        session.undo()
        XCTAssertEqual(authoring.property("speed")?.text, "Speed", "one undo step for the run of edits")
        XCTAssertEqual(session.undoManager.redoActionName, "Change Label")
    }

    func testUpdateCannotRenameBehindTheBindingsBack() {
        authoring.update("speed", actionName: "x") { $0.key = "other" }
        XCTAssertNotNil(authoring.property("speed"))
        XCTAssertNil(authoring.property("other"))
    }

    func testRemoveAndMove() {
        authoring.remove(["style", "folder"], actionName: "Remove")
        XCTAssertEqual(authoring.properties.map(\.key), ["schemecolor", "showlogo", "speed", "blurstrength", "showblur"])
        // Drag "showblur" (4) above "blurstrength" (3), as a list's move does.
        authoring.move(fromOffsets: IndexSet(integer: 4), toOffset: 3, actionName: "Move")
        XCTAssertEqual(authoring.properties.map(\.key), ["schemecolor", "showlogo", "speed", "showblur", "blurstrength"])
        // And the first to the end.
        authoring.move(fromOffsets: IndexSet(integer: 0), toOffset: 5, actionName: "Move")
        XCTAssertEqual(authoring.properties.map(\.key), ["showlogo", "speed", "showblur", "blurstrength", "schemecolor"])
        session.undo()
        session.undo()
        session.undo()
        XCTAssertEqual(authoring.properties.map(\.key).count, 7)
    }

    func testRenameRepointsConditionsAndBindings() throws {
        // The fixture's blur effect visibility is authored as bound to "showblur".
        XCTAssertEqual(session.fields(boundTo: "showblur").map(\.path), [.effect(1)])
        session.bind("alpha", of: 13, to: SceneUserBinding(name: "showblur"), actionName: "Bind")
        XCTAssertTrue(authoring.rename("showblur", to: "blur_on", actionName: "Rename"))
        XCTAssertEqual(authoring.property("blurstrength")?.condition, "blur_on.value == true")
        XCTAssertTrue(session.fields(boundTo: "showblur").isEmpty)
        XCTAssertEqual(session.fields(boundTo: "blur_on").map(\.layer), [10, 13])
        XCTAssertFalse(authoring.rename("speed", to: "blur_on", actionName: "Rename"), "taken")
        XCTAssertFalse(authoring.rename("speed", to: "9speed", actionName: "Rename"), "invalid")
        session.undo()
        XCTAssertEqual(authoring.property("blurstrength")?.condition, "showblur.value == true", "one step undoes it all")
        XCTAssertEqual(session.fields(boundTo: "showblur").count, 2)
    }

    func testRenamingLeavesStringsAndOtherNamesAlone() {
        XCTAssertEqual(UserPropertyAuthoring.renaming("blur", to: "soft", in: #"blur.value == "blur" && blurry.value && x.blur"#),
                       #"soft.value == "blur" && blurry.value && x.blur"#)
    }

    // MARK: Conditions

    func testConditionsEvaluateTheSubsetAuthorsUse() {
        let values = ["clock": "1", "style": "cycle", "mode": "dual", "on": "true", "size": "0.5"]
        XCTAssertTrue(UserPropertyConditionExpression("clock.value == 1").evaluate(values))
        XCTAssertTrue(UserPropertyConditionExpression("on.value == true").evaluate(values))
        XCTAssertTrue(UserPropertyConditionExpression("on.value").evaluate(values))
        XCTAssertFalse(UserPropertyConditionExpression("!on.value").evaluate(values))
        XCTAssertFalse(UserPropertyConditionExpression(#"style.value == "cycle" && mode.value != "dual""#).evaluate(values))
        XCTAssertTrue(UserPropertyConditionExpression(#"(style.value === 'cycle' || mode.value == 'x') && size.value > 0.25"#).evaluate(values))
        XCTAssertTrue(UserPropertyConditionExpression("clock.value ==").evaluate(values), "unreadable: shown")
        XCTAssertFalse(UserPropertyConditionExpression("clock.value ==").isUnderstood)
        XCTAssertEqual(UserPropertyConditionExpression("a.value == 1 && b.value").referencedKeys, ["a", "b"])
    }

    func testConditionRulesRoundTrip() throws {
        let rule = try XCTUnwrap(UserPropertyConditionRule(#"style.value == "cycle""#))
        XCTAssertEqual(rule.key, "style")
        XCTAssertEqual(rule.comparison, .equal)
        XCTAssertEqual(rule.value, "cycle")
        XCTAssertEqual(rule.condition, #"style.value == "cycle""#)
        XCTAssertEqual(UserPropertyConditionRule("clock.value !== 1")?.condition, "clock.value != 1")
        XCTAssertEqual(UserPropertyConditionRule("size.value >= 0.5")?.comparison, .greaterOrEqual)
        XCTAssertEqual(UserPropertyConditionRule(key: "on", value: "true").condition, "on.value == true")
        XCTAssertNil(UserPropertyConditionRule("a.value == 1 && b.value"), "two comparisons are an expression")
        XCTAssertNil(UserPropertyConditionRule("a.value == b.value"))
    }

    func testConditionsShowAndHideInThePreviewModel() {
        authoring.update("blurstrength", actionName: "Condition") {
            $0.condition = UserPropertyConditionRule(key: "style", value: "b").condition
        }
        let condition = UserPropertyConditionExpression(authoring.property("blurstrength")?.condition ?? "")
        var values = Dictionary(uniqueKeysWithValues: authoring.properties.map { ($0.key, $0.defaultText) })
        XCTAssertFalse(condition.evaluate(values), "style starts at a")
        values["style"] = "b"
        XCTAssertTrue(condition.evaluate(values))
    }

    // MARK: Round trip

    func testOverlayRoundTripAndProjectJSON() throws {
        authoring.add(.combo, label: "Mode", actionName: "Add")
        authoring.update("mode", actionName: "Options") {
            $0.options = [.init(label: "Day", value: "day"), .init(label: "Night", value: "night")]
            $0.value = .string("night")
            $0.condition = "showlogo.value == true"
        }
        authoring.update("speed", actionName: "Range") {
            $0.maximum = 5
            $0.decimals = 2
            $0.fraction = false
        }
        authoring.remove(["folder"], actionName: "Remove")
        let edited = authoring.properties

        // The overlay saves and loads the list exactly.
        let reloaded = try SceneEditOverlay.decoded(from: session.overlay.encoded())
        XCTAssertEqual(reloaded.authoring?.properties, edited)

        // project.json gets them in order, and reads back the same.
        let written = try XCTUnwrap(reloaded.authoring).appliedProject(to: Self.projectJSON)
        XCTAssertEqual(UserPropertyAuthoring.read(projectJSON: written), edited)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        XCTAssertEqual(root["workshopid"] as? String, "42", "the rest of project.json is left alone")
        let entries = try XCTUnwrap((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])
        XCTAssertNil(entries["folder"])
        XCTAssertEqual(entries["mode"]?["type"] as? String, "combo")
        XCTAssertEqual(entries["mode"]?["value"] as? String, "night")
        XCTAssertEqual(entries["mode"]?["condition"] as? String, "showlogo.value == true")
        // WE's numbering: `index` the place without the scheme colour, `order` 100 + `index`.
        XCTAssertEqual((entries["mode"]?["order"] as? NSNumber)?.intValue, 105)
        XCTAssertEqual((entries["mode"]?["index"] as? NSNumber)?.intValue, 5)
        XCTAssertEqual((entries["schemecolor"]?["order"] as? NSNumber)?.intValue, 0)
        XCTAssertNil(entries["schemecolor"]?["index"])
        XCTAssertEqual((entries["speed"]?["precision"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual(entries["speed"]?["fraction"] as? Bool, false)
        XCTAssertEqual(entries["speed"]?["editable"] as? Bool, true)
        XCTAssertEqual(entries["showlogo"]?["value"] as? Bool, true)
        XCTAssertEqual(entries["schemecolor"]?["value"] as? String, "0.1 0.2 0.3")
    }

    /// Save as New Wallpaper writes the bindings into scene.json and the properties into
    /// project.json of the copy.
    func testSaveAsLocalWallpaperWritesPropertiesAndBindings() throws {
        let root = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "42", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Self.projectJSON.write(to: source.appending(path: "project.json"))
        try Fixtures.sceneData.write(to: source.appending(path: "scene.json"))
        authoring.addAndBind(.slider, label: "Logo opacity", path: "alpha", of: 13, defaultValue: .number(0.6),
                             actionName: "Bind")
        let overlay = session.overlay
        let folder = try LocalWallpaperWriter().save(
            .init(directory: source, sceneFile: "scene.json"), scene: overlay.applied(to: Fixtures.sceneData),
            title: "Rain (Edited)", into: root.appending(path: "Library"),
            editProject: { overlay.authoring?.applyProperties(to: &$0) })
        let project = try Data(contentsOf: folder.appending(path: "project.json"))
        let properties = UserPropertyAuthoring.read(projectJSON: project)
        XCTAssertEqual(properties.last?.key, "logoopacity")
        XCTAssertEqual(properties.last?.value, .number(0.6))
        let root2 = try XCTUnwrap(JSONSerialization.jsonObject(with: project) as? [String: Any])
        XCTAssertEqual(root2["title"] as? String, "Rain (Edited)")
        XCTAssertNil(root2["workshopid"])
        let scene = try Data(contentsOf: folder.appending(path: "scene.json"))
        let alpha = try XCTUnwrap(try Fixtures.object(13, in: scene)["alpha"] as? [String: Any])
        XCTAssertEqual(alpha["user"] as? String, "logoopacity")
    }

    func testUneditedPropertiesLeaveProjectJSONAsItIs() throws {
        XCTAssertEqual(try SceneAuthoring().appliedProject(to: Self.projectJSON), Self.projectJSON)
    }

    func testPropertyEditsDontChangeTheSceneDigest() {
        let before = session.overlay.digest
        authoring.add(.bool, label: "Clock", actionName: "Add")
        XCTAssertEqual(session.overlay.digest, before, "project.json only: the scene isn't parsed again")
        XCTAssertTrue(session.overlay.hasSceneEdits, "but the wallpaper is edited (Revert, Save as New Wallpaper)")
        session.revert(to: SceneEditOverlay(), actionName: "Revert to Saved")
        XCTAssertFalse(authoring.isEdited)
    }

    func testCandidatesForAField() {
        XCTAssertEqual(authoring.candidates(for: .bool).map(\.key), ["showlogo", "style", "showblur"],
                       "a flag follows a checkbox or a combo")
        XCTAssertEqual(authoring.candidates(for: .slider).map(\.key), ["showlogo", "speed", "blurstrength", "showblur"])
        XCTAssertEqual(authoring.candidates(for: .color).map(\.key), ["schemecolor"])
    }

    func testAddAndBindIsOneStep() throws {
        let key = authoring.addAndBind(.slider, label: "Logo opacity", path: "alpha", of: 13,
                                       defaultValue: .number(0.8), actionName: "Bind")
        XCTAssertEqual(key, "logoopacity")
        XCTAssertEqual(authoring.property(key)?.value, .number(0.8))
        XCTAssertEqual(session.drivers("alpha", of: 13).user?.name, key)
        XCTAssertEqual(session.binding("alpha", of: 13), .userProperty(key))
        session.undo()
        XCTAssertNil(authoring.property(key))
        XCTAssertNil(session.drivers("alpha", of: 13).user)
    }
}
