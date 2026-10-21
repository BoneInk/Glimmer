import XCTest
@testable import OWESceneEditing

/// The Scene Options and Project Settings through the overlay: each change of scene.json's
/// `general` is one undo step and lands in the applied scene; a value back to the authored one
/// (or WE's default) drops the edit; a user-bound setting isn't edited; camera parallax set by
/// hand survives the depth-parallax rule; the resolution resizes the outline; the title is a
/// project.json edit that leaves the scene cache key alone.
@MainActor
final class SceneGeneralEditTests: XCTestCase {
    private static let sceneJSON = """
    {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"},
     "general": {"orthogonalprojection": {"width": 1920, "height": 1080}, "clearcolor": "0 0 0",
                 "bloomstrength": 1.5, "bloom": {"user": "hdr", "value": true},
                 "camerashake": {"script": "export function update(v) { return v; }", "value": false}},
     "objects": [{"id": 1, "name": "Background", "image": "models/bg.json", "size": "1920 1080", "origin": "960 540 0"}]}
    """
    private var session: SceneEditSession!
    private var undoManager: UndoManager!
    private var sceneData: Data { Data(Self.sceneJSON.utf8) }

    override func setUp() async throws {
        undoManager = UndoManager()
        undoManager.groupsByEvent = false
        session = SceneEditSession(outline: try SceneOutline(sceneData: sceneData), undoManager: undoManager)
    }

    private func appliedGeneral() throws -> [String: Any] {
        let root = try JSONSerialization.jsonObject(with: try session.overlay.applied(to: sceneData)) as? [String: Any]
        return try XCTUnwrap(root?["general"] as? [String: Any])
    }

    func testASettingIsOneUndoStepAndReachesTheScene() throws {
        XCTAssertEqual(session.generalNumber("bloomstrength"), 1.5, "the authored value")
        XCTAssertEqual(session.generalNumber("bloomthreshold"), 0.65, accuracy: 1e-9, "WE's default")
        session.setGeneral(.number(3), for: "bloomstrength", actionName: "Change")
        session.setGeneral(.string("1 0.5 0"), for: "fogdistancecolor", actionName: "Change")
        session.setGeneral(.bool(true), for: "fogdistance", actionName: "Change")
        XCTAssertEqual(session.generalNumber("bloomstrength"), 3)
        let general = try appliedGeneral()
        XCTAssertEqual(general["bloomstrength"] as? Double, 3)
        XCTAssertEqual(general["fogdistancecolor"] as? String, "1 0.5 0")
        XCTAssertEqual(general["fogdistance"] as? Bool, true)
        XCTAssertEqual(general["clearcolor"] as? String, "0 0 0", "untouched settings stay")

        session.undo()
        XCTAssertNil(session.overlay.generalSetting("fogdistance"))
        session.undo()
        session.undo()
        XCTAssertNil(session.overlay.general, "every edit undone")
        XCTAssertFalse(session.canUndo)
    }

    func testTheAuthoredValueOrWEsDefaultDropsTheEdit() {
        session.setGeneral(.number(3), for: "bloomstrength", actionName: "Change")
        session.setGeneral(.number(1.5), for: "bloomstrength", actionName: "Change")
        XCTAssertNil(session.overlay.generalSetting("bloomstrength"))
        session.setGeneral(.string("1 1 1"), for: "bloomtint", actionName: "Change")
        XCTAssertNil(session.overlay.generalSetting("bloomtint"), "WE's default tint is no edit")
        XCTAssertTrue(session.overlay.isEmpty)
    }

    func testAUserBoundSettingIsNotEditedAndAScriptedOneKeepsItsScript() throws {
        XCTAssertEqual(session.generalBinding("bloom"), .userProperty("hdr"))
        session.setGeneral(.bool(false), for: "bloom", actionName: "Change")
        XCTAssertNil(session.overlay.generalSetting("bloom"))

        XCTAssertEqual(session.generalBinding("camerashake"), .driven)
        session.setGeneral(.bool(true), for: "camerashake", actionName: "Change")
        let shake = try XCTUnwrap(try appliedGeneral()["camerashake"] as? [String: Any])
        XCTAssertNotNil(shake["script"], "the script keeps running from the edited value")
        XCTAssertEqual(shake["value"] as? Bool, true)
    }

    func testCameraParallaxSetByHandStays() {
        session.setGeneral(.bool(true), for: "cameraparallax", actionName: "Change")
        session.setGeneral(.number(0.8), for: "cameraparallaxamount", actionName: "Change")
        XCTAssertEqual(session.overlay.generalSetting("cameraparallax"), .bool(true),
                       "without depth parallax the editor's camera parallax isn't dropped")
        XCTAssertEqual(session.generalNumber("cameraparallaxamount"), 0.8)
    }

    func testPhysicsSettingsRoundTripThroughTheOverlayFile() throws {
        session.setGeneral(.bool(true), for: "windenabled", actionName: "Change")
        session.setGeneral(.string("1 0 0"), for: "winddirection", actionName: "Change")
        session.setGeneral(.number(2.5), for: "windstrength", actionName: "Change")
        session.setGeneral(.string("0 -2 0"), for: "gravitydirection", actionName: "Change")
        let decoded = try SceneEditOverlay.decoded(from: try session.overlay.encoded())
        XCTAssertEqual(decoded.general, session.overlay.general)
        let general = try appliedGeneral()
        XCTAssertEqual(general["windenabled"] as? Bool, true)
        XCTAssertEqual(general["winddirection"] as? String, "1 0 0")
        XCTAssertEqual(general["windstrength"] as? Double, 2.5)
        XCTAssertEqual(general["gravitydirection"] as? String, "0 -2 0")
    }

    func testTheResolutionResizesTheScene() throws {
        XCTAssertEqual(session.projectResolution, SIMD2(1920, 1080))
        session.setProjectResolution(SIMD2(2560, 1440), actionName: "Change")
        XCTAssertEqual(session.projectResolution, SIMD2(2560, 1440))
        XCTAssertEqual(session.outline.size, SIMD2(2560, 1440), "the canvas reads the edited size")
        let projection = try XCTUnwrap(try appliedGeneral()["orthogonalprojection"] as? [String: Any])
        XCTAssertEqual(projection["width"] as? Double, 2560)
        XCTAssertEqual(projection["height"] as? Double, 1440)
        session.undo()
        XCTAssertEqual(session.outline.size, SIMD2(1920, 1080))
    }

    func testTheTitleIsAProjectEdit() throws {
        let digest = session.overlay.digest
        session.setProjectTitle("  Night City  ", authored: "City", actionName: "Change")
        XCTAssertEqual(session.projectTitle, "Night City")
        XCTAssertEqual(session.overlay.digest, digest, "the title doesn't change the scene")
        XCTAssertFalse(session.overlay.isEmpty)
        var project: [String: Any] = ["title": "City", "type": "scene"]
        session.overlay.project?.apply(to: &project)
        XCTAssertEqual(project["title"] as? String, "Night City")
        let decoded = try SceneEditOverlay.decoded(from: try session.overlay.encoded())
        XCTAssertEqual(decoded.project?.title, "Night City")

        session.setProjectTitle("City", authored: "City", actionName: "Change")
        XCTAssertNil(session.overlay.project, "the authored title is no edit")
        session.setProjectTitle("   ", authored: "City", actionName: "Change")
        XCTAssertNil(session.overlay.project, "nor is an empty one")
    }

    func testWritingTheProjectEditsIntoAWallpaper() throws {
        let folder = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(#"{"title": "City", "type": "scene", "file": "scene.json"}"#.utf8).write(to: folder.appending(path: "project.json"))
        try LocalWallpaperWriter().writeProjectEdits(SceneProjectEdits(title: "Night City"), into: folder)
        let project = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "project.json"))) as? [String: Any]
        XCTAssertEqual(project?["title"] as? String, "Night City")
        XCTAssertEqual(project?["file"] as? String, "scene.json")
    }
}
