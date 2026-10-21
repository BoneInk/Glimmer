import XCTest
@testable import OWESceneEditing

/// New / Duplicate Effect as WE's editor makes them: the folder name from the author's name, the
/// files copied into the effect's folder (a one-material effect renamed after it), `effect.json`
/// as WE writes it, and the files kept in the overlay where the loader and Save read them.
@MainActor
final class CustomEffectTests: XCTestCase {
    /// A blank effect laid out as WE's `effects/_empty` is (written for this test).
    private static let template: [String: String] = [
        "effects/_empty/effect.json": """
        {"version": 1, "replacementkey": "empty", "group": "colorize",
         "passes": [{"material": "materials/effects/empty.json"}],
         "dependencies": ["materials/effects/empty.json", "shaders/effects/empty.frag", "shaders/effects/empty.vert"]}
        """,
        "effects/_empty/materials/effects/empty.json": """
        {"passes": [{"shader": "effects/empty", "blending": "normal", "depthtest": "disabled", "depthwrite": "disabled", "cullmode": "nocull"}]}
        """,
        "effects/_empty/shaders/effects/empty.vert": "attribute vec3 a_Position;\nvoid main() {}\n",
        "effects/_empty/shaders/effects/empty.frag": "uniform sampler2D g_Texture0;\nvoid main() {}\n",
    ]

    /// A two-material effect at the asset root, with a description, preview and an FBO.
    private static let twoPass: [String: String] = [
        "effects/glow/effect.json": """
        {"version": 1, "name": "ui_glow_title", "description": "ui_glow_description", "group": "enhance",
         "preview": "preview/project.json", "fbos": [{"name": "half", "scale": 2}],
         "passes": [{"material": "materials/effects/glow_a.json", "target": "half"},
                    {"material": "materials/effects/glow_b.json", "bind": [{"name": "half", "index": 1}]}]}
        """,
        "materials/effects/glow_a.json": #"{"passes": [{"shader": "effects/glow_a"}]}"#,
        "materials/effects/glow_b.json": #"{"passes": [{"shader": "effects/glow_b", "combos": {"MODE": 1}}]}"#,
        "shaders/effects/glow_a.vert": "// a vert\n", "shaders/effects/glow_a.frag": "// a frag\n",
        "shaders/effects/glow_b.vert": "// b vert\n", "shaders/effects/glow_b.frag": "// b frag\n",
    ]

    private static func reader(_ files: [String: String]) -> (String) -> Data? {
        { path in files[path].map { Data($0.utf8) } }
    }

    func testFolderNameFollowsWE() {
        XCTAssertEqual(CustomEffect.identifier(for: "Pulse+"), "pulse_")
        XCTAssertEqual(CustomEffect.identifier(for: "Iris Movement +"), "iris_movement__")
        XCTAssertEqual(CustomEffect.identifier(for: "MyFirstShader"), "myfirstshader")
        XCTAssertEqual(CustomEffect.identifier(for: "Color Grading: Extension"), "color_grading__extension")
        // Every UTF-8 byte of a character outside a–z and 0–9 is one underscore.
        XCTAssertEqual(CustomEffect.identifier(for: "文本-渐变"), String(repeating: "_", count: 13))
    }

    func testNewEffectCopiesTheBlankEffectRenamed() throws {
        let effect = try CustomEffect.make(named: "Desaturate", read: Self.reader(Self.template))
        XCTAssertEqual(effect.file, "effects/desaturate/effect.json")
        XCTAssertEqual(Set(effect.files.keys), [
            "effects/desaturate/effect.json", "effects/desaturate/materials/effects/desaturate.json",
            "effects/desaturate/shaders/effects/desaturate.vert", "effects/desaturate/shaders/effects/desaturate.frag",
        ])
        XCTAssertEqual(effect.files["effects/desaturate/effect.json"], """
        {
        \t"dependencies" :\u{20}
        \t[
        \t\t"materials/effects/desaturate.json",
        \t\t"shaders/effects/desaturate.frag",
        \t\t"shaders/effects/desaturate.vert"
        \t],
        \t"editable" : true,
        \t"group" : "localeffects",
        \t"name" : "Desaturate",
        \t"passes" :\u{20}
        \t[
        \t\t{
        \t\t\t"material" : "materials/effects/desaturate.json"
        \t\t}
        \t],
        \t"replacementkey" : "desaturate",
        \t"version" : 1
        }
        """)
        XCTAssertEqual(effect.files["effects/desaturate/materials/effects/desaturate.json"], """
        {
        \t"passes" :\u{20}
        \t[
        \t\t{
        \t\t\t"blending" : "normal",
        \t\t\t"cullmode" : "nocull",
        \t\t\t"depthtest" : "disabled",
        \t\t\t"depthwrite" : "disabled",
        \t\t\t"shader" : "effects/desaturate"
        \t\t}
        \t]
        }
        """)
        XCTAssertEqual(effect.files["effects/desaturate/shaders/effects/desaturate.frag"], Self.template["effects/_empty/shaders/effects/empty.frag"])
    }

    func testDuplicateOfSeveralMaterialsKeepsTheirNames() throws {
        let effect = try CustomEffect.make(named: "My Glow", from: "effects/glow/effect.json", read: Self.reader(Self.twoPass))
        XCTAssertEqual(Set(effect.files.keys), [
            "effects/my_glow/effect.json",
            "effects/my_glow/materials/effects/glow_a.json", "effects/my_glow/materials/effects/glow_b.json",
            "effects/my_glow/shaders/effects/glow_a.vert", "effects/my_glow/shaders/effects/glow_a.frag",
            "effects/my_glow/shaders/effects/glow_b.vert", "effects/my_glow/shaders/effects/glow_b.frag",
        ])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(effect.files[effect.file]!.utf8)) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "My Glow")
        XCTAssertEqual(json["group"] as? String, "localeffects")
        XCTAssertNil(json["description"])
        XCTAssertNil(json["preview"])
        XCTAssertNotNil(json["fbos"], "the effect's own render targets stay")
        let passes = try XCTUnwrap(json["passes"] as? [[String: Any]])
        XCTAssertEqual(passes.map { $0["material"] as? String }, ["materials/effects/glow_a.json", "materials/effects/glow_b.json"])
        XCTAssertEqual(passes[0]["target"] as? String, "half")
        XCTAssertTrue(effect.files["effects/my_glow/materials/effects/glow_b.json"]!.contains(#""MODE" : 1"#))
    }

    func testMissingFilesAndEmptyNamesAreErrors() {
        XCTAssertThrowsError(try CustomEffect.make(named: "  ", read: Self.reader(Self.template))) { error in
            XCTAssertEqual(error as? CustomEffect.MakeError, .emptyName)
        }
        var broken = Self.template
        broken["effects/_empty/shaders/effects/empty.vert"] = nil
        XCTAssertThrowsError(try CustomEffect.make(named: "X", read: Self.reader(broken))) { error in
            XCTAssertEqual(error as? CustomEffect.MakeError, .unreadable("shaders/effects/empty.vert"))
        }
    }

    func testStyledJSONWritesShortArraysOnOneLine() {
        XCTAssertEqual(SceneJSONValue.object(["a": .array([.number(1), .number(2)]), "b": .object([:]), "c": .string("x/\"y\"")]).editorJSON, """
        {
        \t"a" : [ 1, 2 ],
        \t"b" : {},
        \t"c" : "x/\\"y\\""
        }
        """)
        XCTAssertEqual(SceneJSONValue.number(0.5).editorJSON, "0.5")
    }

    // MARK: In the overlay

    func testFilesLiveInTheOverlayAndAreUndoable() throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        let session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        let effect = try CustomEffect.make(named: "Desaturate", read: Self.reader(Self.template))
        session.createCustomEffect(effect, actionName: "Create New Effect")
        XCTAssertEqual(session.overlay.customEffectFiles, ["effects/desaturate/effect.json"])
        XCTAssertTrue(session.overlay.hasSceneEdits)
        XCTAssertEqual(session.overlay.structureOnly.effectFiles, session.overlay.effectFiles,
                       "a change of an effect's files is never drawn live")
        let data = session.overlay.editorFileData()
        XCTAssertEqual(data["effects/desaturate/shaders/effects/desaturate.frag"].map { String(decoding: $0, as: UTF8.self) },
                       effect.files["effects/desaturate/shaders/effects/desaturate.frag"])
        XCTAssertEqual(try session.overlay.editorFiles().keys.sorted(), effect.files.keys.sorted())
        XCTAssertEqual(try SceneEditOverlay.decoded(from: try session.overlay.encoded()), session.overlay)

        session.setEffectFile("effects/desaturate/shaders/effects/desaturate.frag", text: "// edited\n", actionName: "Edit Shader")
        XCTAssertEqual(session.overlay.effectFile("effects/desaturate/shaders/effects/desaturate.frag"), "// edited\n")
        session.undo()
        XCTAssertEqual(session.overlay.effectFile("effects/desaturate/shaders/effects/desaturate.frag"),
                       effect.files["effects/desaturate/shaders/effects/desaturate.frag"])

        session.deleteCustomEffect(effect.file, actionName: "Delete Effect")
        XCTAssertNil(session.overlay.effectFiles)
        XCTAssertTrue(session.overlay.isEmpty)
        session.undo()
        XCTAssertEqual(session.overlay.customEffectFiles, ["effects/desaturate/effect.json"])
    }

    func testMyEffectsComeFirst() {
        var mine = EffectCatalogEntry(file: "effects/zz/effect.json", title: "Zed", group: "localeffects", groupTitle: "localeffects")
        mine.isEditable = true
        let builtIn = EffectCatalogEntry(file: "effects/blur/effect.json", title: "Blur", group: "blur", groupTitle: "Blur")
        let workshop = EffectCatalogEntry(file: "effects/workshop/1/x/effect.json", title: "X", groupTitle: "Workshop", isWorkshop: true)
        XCTAssertEqual(EffectCatalog.grouped([workshop, builtIn, mine]).map(\.title), ["localeffects", "Blur", "Workshop"])
    }

    func testEffectFilesAreFoundAtTheirDepth() {
        XCTAssertEqual(CustomEffect.effectFiles(in: ["effects/a/effect.json", "effects/a/materials/effects/a.json",
                                                     "effects/workshop/1/b/effect.json", "effects//effect.json", "effects/a/effect.json"]),
                       ["effects/a/effect.json"])
    }
}
