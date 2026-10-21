import XCTest
@testable import OWESceneEditing

/// The property types WE's editor creates beside the value ones: group, texture (`scenetexture`),
/// user shortcut, and a folder's fetch mode and a file's type, written as WE's editor writes them
/// (`EditorUserPropertyDetailsModalCtrl`), and the texture slots bound to a texture or a shortcut.
@MainActor
final class UserPropertyTypesTests: XCTestCase {
    private var session: SceneEditSession!
    private var authoring: UserPropertyAuthoring!

    override func setUp() async throws {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: Fixtures.sceneData), undoManager: undoManager)
        session.coalescingInterval = 0
        authoring = UserPropertyAuthoring(session: session, projectJSON: UserPropertyAuthoringTests.projectJSON)
    }

    func testNewKindsAreWrittenAsWEsEditorWritesThem() throws {
        authoring.add(.group, label: "Clock", actionName: "Add")
        authoring.add(.sceneTexture, label: "Background", actionName: "Add")
        authoring.add(.userShortcut, label: "Shortcut 1", actionName: "Add")
        authoring.add(.directory, label: "Slides", actionName: "Add")
        let written = try XCTUnwrap(session.overlay.authoring).appliedProject(to: UserPropertyAuthoringTests.projectJSON)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let entries = try XCTUnwrap((root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]])
        XCTAssertEqual(entries["clock"]?["type"] as? String, "group")
        XCTAssertEqual(entries["clock"]?["value"] as? String, "", "a group has an empty value")
        XCTAssertEqual(entries["background"]?["type"] as? String, "scenetexture")
        XCTAssertEqual(entries["background"]?["value"] as? String, "")
        XCTAssertEqual(entries["shortcut1"]?["type"] as? String, "usershortcut")
        XCTAssertEqual(entries["shortcut1"]?["value"] as? String, "")
        XCTAssertEqual(entries["slides"]?["mode"] as? String, "ondemand", "WE's first fetch mode")
        XCTAssertEqual(UserPropertyAuthoring.read(projectJSON: written).map(\.kind).suffix(4),
                       [.group, .sceneTexture, .userShortcut, .directory])
    }

    func testKindsWithoutADefaultOrValue() {
        XCTAssertFalse(UserPropertyDraft.Kind.group.hasValue)
        XCTAssertFalse(UserPropertyDraft.Kind.text.hasValue)
        XCTAssertTrue(UserPropertyDraft.Kind.sceneTexture.hasValue)
        XCTAssertFalse(UserPropertyDraft.Kind.sceneTexture.hasDefault, "only the user picks a texture")
        XCTAssertFalse(UserPropertyDraft.Kind.userShortcut.hasDefault)
        XCTAssertTrue(UserPropertyDraft.Kind.slider.hasDefault)
        XCTAssertTrue(authoring.candidates(for: .bool).allSatisfy { $0.kind != .group })
    }

    func testFetchModeAndFileType() throws {
        var folder = try XCTUnwrap(authoring.property("folder"))
        XCTAssertNil(folder.fetchMode, "\"fetch\" isn't one of WE's modes")
        authoring.update("folder", actionName: "Mode") { $0.fetchMode = .fetchAll }
        folder = try XCTUnwrap(authoring.property("folder"))
        XCTAssertEqual(folder.json(order: 0)["mode"], .string("fetchall"))

        authoring.add(.file, label: "Picture", actionName: "Add")
        authoring.update("picture", actionName: "Type") { $0.fileType = .video }
        XCTAssertEqual(authoring.property("picture")?.json(order: 0)["fileType"], .string("video"))
        authoring.update("picture", actionName: "Type") { $0.fileType = nil }
        XCTAssertNil(authoring.property("picture")?.json(order: 0)["fileType"])

        // Another type doesn't keep a folder's mode.
        var changed = folder
        changed.kind = .textInput
        XCTAssertNil(changed.json(order: 0)["mode"])
    }

    func testGroupsFoldTheFollowingProperties() {
        let list: [UserPropertyDraft] = [
            .new(.bool, key: "a", text: "A"), .new(.group, key: "g1", text: "One"), .new(.slider, key: "b", text: "B"),
            .new(.color, key: "c", text: "C"), .new(.group, key: "g2", text: "Two"), .new(.bool, key: "d", text: "D"),
        ]
        let groups = UserPropertyGroup.groups(list)
        XCTAssertEqual(groups.map { $0.header?.key }, [nil, "g1", "g2"])
        XCTAssertEqual(groups.map { $0.members.map(\.key) }, [["a"], ["b", "c"], ["d"]])
        XCTAssertEqual(UserPropertyGroup.group(of: "c", in: list), "g1")
        XCTAssertNil(UserPropertyGroup.group(of: "a", in: list))
        XCTAssertEqual(UserPropertyGroup.groups(Array(list.dropFirst())).first?.header?.key, "g1",
                       "no empty leading run")
    }

    func testBindingTexturesToATextureAndAShortcut() throws {
        authoring.add(.sceneTexture, label: "Background", actionName: "Add")
        authoring.add(.userShortcut, label: "Shortcut", actionName: "Add")
        XCTAssertEqual(authoring.textureLayers.map(\.id), [10, 13, 14], "the image layers")

        authoring.bindTexture(UserTextureBinding(layer: 10), to: "background", actionName: "Bind")
        authoring.bindTexture(UserTextureBinding(layer: 13), to: "shortcut", actionName: "Bind")
        XCTAssertEqual(authoring.textureBindings(of: "background"), [UserTextureBinding(layer: 10)])
        XCTAssertEqual(authoring.textureProperty(of: UserTextureBinding(layer: 13)), "shortcut")

        let scene = try session.overlay.applied(to: Fixtures.sceneData)
        let background = try XCTUnwrap(try Fixtures.object(10, in: scene)["instance"] as? [String: Any])
        XCTAssertEqual(background["usertextures"] as? [String], ["background"])
        let logo = try XCTUnwrap(try Fixtures.object(13, in: scene)["instance"] as? [String: Any])
        let link = try XCTUnwrap((logo["usertextures"] as? [[String: String]])?.first)
        XCTAssertEqual(link, ["name": "shortcut", "type": "usershortcut"])

        // A rename re-points the links in the same step.
        XCTAssertTrue(authoring.rename("background", to: "wall", actionName: "Rename"))
        XCTAssertEqual(authoring.textureBindings(of: "wall"), [UserTextureBinding(layer: 10)])
        XCTAssertTrue(authoring.rename("shortcut", to: "launcher", actionName: "Rename"))
        XCTAssertEqual(authoring.textureProperty(of: UserTextureBinding(layer: 13)), "launcher")
        session.undo()
        XCTAssertEqual(authoring.textureProperty(of: UserTextureBinding(layer: 13)), "shortcut")

        authoring.unbindTexture(UserTextureBinding(layer: 10), actionName: "Unbind")
        XCTAssertTrue(authoring.textureBindings(of: "wall").isEmpty)
        XCTAssertNil(session.overlay.field("instance", of: 10), "back to the authored layer: no edit left")
    }

    func testBindingKeepsTheInstancesOtherKeysAndSystemTextures() throws {
        let scene = """
        {"objects": [{"id": 5, "name": "Cover", "image": "models/solid.json", "size": "256 256",
          "instance": {"textures": ["util/white", "mask"], "usertextures": [null, {"name": "$mediaThumbnail", "type": "system"}]}}]}
        """
        session = SceneEditSession(outline: try SceneOutline(sceneData: Data(scene.utf8)))
        authoring = UserPropertyAuthoring(session: session, authored: [.new(.sceneTexture, key: "cover", text: "Cover")])
        XCTAssertNil(authoring.textureProperty(of: UserTextureBinding(layer: 5, slot: 1)), "a system texture is no property")
        authoring.bindTexture(UserTextureBinding(layer: 5), to: "cover", actionName: "Bind")
        guard case .object(let instance)? = session.value("instance", of: 5) else { return XCTFail("no instance") }
        XCTAssertEqual(instance["textures"], .array([.string("util/white"), .string("mask")]))
        XCTAssertEqual(instance["usertextures"], .array([
            .string("cover"), .object(["name": .string("$mediaThumbnail"), "type": .string("system")]),
        ]))
    }
}
