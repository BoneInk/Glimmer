import XCTest
import OWEControlProtocol
import OWEEditor
import OWESceneEditing
@testable import OpenWallpaperEngine

/// Headless edits against the editor's own path: the same edits made through the session calls
/// the editor's controls make give the same overlay and the same undo stack, in the Wallpaper
/// Editor's draft; the running instances hear only its save; and an open editor window takes them
/// as an undo step through the change sync.
@MainActor
final class MCPSceneHeadlessTests: XCTestCase {
    private var fixture: MCPSceneFixture!

    override func setUp() async throws {
        fixture = try MCPSceneFixture()
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    private func edit(_ object: [String: JSONValue]) -> ControlParameters { ControlParameters(object) }

    /// An undo manager that groups by commit: a synchronous test has no event loop turns between steps.
    private static func undoManagerPerStep() -> UndoManager {
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        return undoManager
    }

    /// Each edit as its own request, against the same edit made the way the editor makes it: after
    /// every step, and back through every undo, the two overlays are the same.
    func testHeadlessEditsMatchTheEditorsPath() throws {
        let document = try fixture.service().document(for: fixture.wallpaper)
        // One undo step per control, as each of the editor's events is one.
        let editor = SceneEditSession(outline: try SceneOutline(sceneData: MCPSceneFixture.scene), undoManager: Self.undoManagerPerStep())
        let steps: [(ControlParameters, (SceneEditSession) -> Void)] = [
            (edit(["op": "set_origin", "layer": 4, "value": "10 20 0"]), { session in
                var transform = session.transform(of: 4)
                transform.origin = SIMD3(10, 20, 0)
                session.setTransform(transform, of: 4, actionName: "Move")
            }),
            (edit(["op": "set_alpha", "layer": 4, "alpha": 0.5]), { $0.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity") }),
            (edit(["op": "set_name", "layer": 5, "name": "Heading"]), { $0.rename(5, to: "Heading", actionName: "Rename") }),
            (edit(["op": "add_layer", "kind": "text", "text": "Hi", "x": 10, "y": 20]), { session in
                let object = SceneLayerFactory.text(name: "Hi", value: "Hi", font: "systemfont_arial", pointSize: 32,
                                                    origin: SIMD2(10, 20))
                session.addLayer(object, actionName: "Add Text Layer")
            }),
            (edit(["op": "remove_layers", "layers": [6]]), { $0.delete([6], actionName: "Delete Layer") }),
            (edit(["op": "set_effect_visible", "layer": 4, "effect": "0", "visible": false]), { session in
                let effect = session.outline.layer(4)!.effects[0]
                session.setEffectVisible(false, effect: effect, of: 4, actionName: "Hide Effect")
            }),
        ]
        var overlays: [SceneEditOverlay] = [editor.overlay]
        for (index, step) in steps.enumerated() {
            _ = try document.apply([step.0], actionName: nil)
            step.1(editor)
            XCTAssertEqual(document.session.overlay, editor.overlay, "after step \(index)")
            overlays.append(editor.overlay)
        }
        XCTAssertEqual(try fixture.draftStore.overlay(for: fixture.identity.rawValue), editor.overlay, "kept as the editor keeps its draft")
        XCTAssertNil(try fixture.store.overlay(for: fixture.identity.rawValue), "the saved overlay is untouched until a save")
        for index in steps.indices.reversed() {
            XCTAssertTrue(document.session.canUndo)
            XCTAssertTrue(editor.canUndo)
            XCTAssertTrue(document.undo())
            editor.undo()
            XCTAssertEqual(document.session.overlay, overlays[index], "undo back to step \(index)")
            XCTAssertEqual(editor.overlay, overlays[index])
        }
        XCTAssertFalse(document.session.canUndo, "one undo step per request, as one per control")
        XCTAssertFalse(editor.canUndo)
    }

    func testTheRunningInstancesHearOnlyTheSave() throws {
        let center = NotificationCenter()
        var notifications: [Notification] = []
        let token = center.addObserver(forName: .sceneEditOverlayDidChange, object: nil, queue: nil) { notifications.append($0) }
        defer { center.removeObserver(token) }
        var saves: [SceneEditOverlay] = []
        let document = try fixture.service(center: center, announceSave: { _, overlay in saves.append(overlay) })
            .document(for: fixture.wallpaper)
        _ = try document.apply([edit(["op": "set_alpha", "layer": 4, "alpha": 0.5])], actionName: nil)
        XCTAssertTrue(notifications.isEmpty, "an edit stays in the draft")
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertTrue(try document.save())
        XCTAssertEqual(notifications.count, 1, "the save is applied once")
        let info = try XCTUnwrap(notifications.first?.userInfo)
        XCTAssertEqual((info["wallpaperDirectory"] as? URL)?.path, fixture.folder.standardizedFileURL.path)
        XCTAssertEqual(info["transient"] as? Bool, false)
        XCTAssertEqual(info["draft"] as? Bool, false, "the displays' instances take it, not the editor's canvas")
        XCTAssertNotNil(info["base"] as? SceneOutline, "measured against the scene's structure: drawn live")
        XCTAssertEqual(saves, [document.session.overlay], "the change sync hears the save")
        XCTAssertFalse(try document.save(), "nothing left to save")
        _ = try document.apply([edit(["op": "set_locked", "layer": 4, "locked": true])], actionName: nil)
        XCTAssertTrue(try document.save())
        XCTAssertEqual(notifications.count, 1, "a lock doesn't change the running scene")
    }

    /// The app writes an MCP edit into the draft and says so; the editor's process hears it, its open
    /// window takes it as an undo step, and nothing reaches the app's instances until the client saves.
    func testAnOpenEditorWindowTakesTheEditAndOnlyTheSaveReachesTheApp() throws {
        let messaging = MCPFakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        let appCenter = NotificationCenter()
        func sync(_ role: WallpaperEditorChangeSync.Role, _ sender: String, _ local: NotificationCenter) -> WallpaperEditorChangeSync {
            var dependencies = WallpaperEditorChangeSync.Dependencies(messaging: messaging, channel: channel, sender: sender,
                                                                      store: fixture.store, local: local,
                                                                      defaults: fixture.defaults)
            dependencies.readScene = { _ in MCPSceneFixture.scene }
            return WallpaperEditorChangeSync(role: role, dependencies: dependencies)
        }
        let appSync = sync(.app, "app", appCenter), editorSync = sync(.editor, "editor", NotificationCenter())
        var appApplied: [SceneEditOverlay] = []
        let token = appCenter.addObserver(forName: .sceneEditOverlayDidChange, object: nil, queue: nil) { notification in
            if let overlay = notification.userInfo?["overlay"] as? SceneEditOverlay { appApplied.append(overlay) }
        }
        defer { appCenter.removeObserver(token) }
        appSync.start()
        editorSync.start()
        defer { appSync.stop(); editorSync.stop() }

        // The editor's window: a session over the draft that adopts what the app writes, as
        // `WallpaperEditorController.adoptSavedOverlay` does, and writes its own changes into it.
        let drafts = fixture.draftStore
        let window = SceneEditSession(outline: try SceneOutline(sceneData: MCPSceneFixture.scene), undoManager: Self.undoManagerPerStep())
        var adopting = false
        window.onChange = { [fixture] overlay in
            guard !adopting else { return }
            try? drafts.saveDraft(overlay, for: fixture!.identity.rawValue) // A temporary store.
        }
        var heard: [(URL, String)] = []
        editorSync.onAppOverlay = { [fixture] folder, actionName, _ in
            heard.append((folder, actionName))
            guard let stored = try? drafts.overlay(for: fixture!.identity.rawValue) else { return } // Read just written.
            adopting = true
            window.edit(actionName: actionName) { $0 = stored }
            adopting = false
        }
        var savesHeard: [URL] = []
        editorSync.onAppDraftSave = { savesHeard.append($0) }

        let service = fixture.service(center: appCenter, announce: { folder, name, step in
            appSync.appOverlayDidSave(folder: folder, actionName: name, step: step)
        }, announceSave: { folder, overlay in
            appSync.appDraftDidSave(folder: folder, overlay: overlay)
        })
        let document = try service.document(for: fixture.wallpaper)
        _ = try document.apply([edit(["op": "set_alpha", "layer": 4, "alpha": 0.25])], actionName: "Fade Picture")

        XCTAssertEqual(heard.count, 1)
        XCTAssertEqual(heard.first?.0.standardizedFileURL.path, fixture.folder.standardizedFileURL.path)
        XCTAssertEqual(heard.first?.1, "Fade Picture", "the window's Edit menu names it")
        XCTAssertEqual(window.overlay, document.session.overlay, "the open window shows the edit")
        XCTAssertEqual(window.undoManager.undoActionName, "Fade Picture")
        XCTAssertTrue(appApplied.isEmpty, "the app's displays don't run the draft")

        // Undo in the window goes into the draft; the client's session reads it.
        window.undo()
        XCTAssertFalse(drafts.hasDraft(for: fixture.identity.rawValue), "back at the saved overlay: nothing unsaved")
        XCTAssertTrue(try document.refresh(), "the client's session reads the window's Undo")
        XCTAssertNil(document.session.overlay.field("alpha", of: 4))
        XCTAssertFalse(document.session.canUndo, "a fresh history: the client can't undo the user's Undo")

        // The client's save reaches the app's instances once and tells the window.
        _ = try document.apply([edit(["op": "set_alpha", "layer": 4, "alpha": 0.5])], actionName: nil)
        XCTAssertTrue(try document.save())
        XCTAssertEqual(appApplied.count, 1)
        XCTAssertEqual(appApplied.first?.field("alpha", of: 4), .number(0.5))
        appSync.applySavedOverlay(of: fixture.folder)
        XCTAssertEqual(appApplied.count, 1, "applied once, not again when the folder or a message reports it")
        XCTAssertEqual(savesHeard.map(\.standardizedFileURL.path), [fixture.folder.standardizedFileURL.path])
    }

    /// The Wallpaper Editor's own window takes what the app saved as one undo step of its Edit
    /// menu (`adoptSavedOverlay`), and its Undo saves the edit away again.
    func testTheEditorWindowAdoptsTheAppsDraft() throws {
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture.folder, hiding: []))
        let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        let store = SceneEditOverlayFiles.draftStore
        defer { try? store.saved.remove(identity.rawValue) } // The isolated tests' store.
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost())
        defer { try? editor.draft.discard(); editor.window.close() } // The isolated tests' draft.
        let resources = FakeSceneEditResources(folder: wallpaper.wallpaperDirectory, identity: identity,
                                               assets: EditorAssetStore(directory: fixture.root.appending(path: "assets")))
        let service = HeadlessSceneEditService(dependencies: .init(store: store, center: NotificationCenter(),
                                                                   resources: { _ in resources }))
        let document = try service.document(for: fixture.wallpaper)
        _ = try document.apply([edit(["op": "set_alpha", "layer": 4, "alpha": 0.25])], actionName: "Fade")

        editor.adoptSavedOverlay(actionName: "Fade")
        // The window groups its undo steps by event: the message that brought the save was one.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        XCTAssertEqual(editor.session.overlay, document.session.overlay)
        XCTAssertEqual(editor.session.undoManager.undoActionName, "Fade")
        editor.adoptSavedOverlay(actionName: "Fade")
        editor.session.undo()
        XCTAssertFalse(editor.session.canUndo, "the same draft twice is one step")
        XCTAssertTrue(try store.overlay(for: identity.rawValue).isEmpty, "Undo in the window goes into the draft")
        XCTAssertNil(try store.saved.overlay(for: identity.rawValue), "and the saved overlay never changed")
    }

    /// The client's Undo and Redo, through the change sync, move the open window's history: one
    /// edit is one step there however often the client undoes and redoes it.
    func testTheClientsUndoAndRedoMoveTheWindowsHistory() throws {
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture.folder, hiding: []))
        let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        let store = SceneEditOverlayFiles.draftStore
        defer { try? store.saved.remove(identity.rawValue) } // The isolated tests' store.
        let messaging = MCPFakeProcessMessaging()
        let channel = AppProcessChannel(isolationTag: "tests")
        func sync(_ role: WallpaperEditorChangeSync.Role, _ sender: String) -> WallpaperEditorChangeSync {
            var dependencies = WallpaperEditorChangeSync.Dependencies(messaging: messaging, channel: channel, sender: sender,
                                                                      store: store.saved, local: NotificationCenter(),
                                                                      defaults: fixture.defaults)
            dependencies.readScene = { _ in MCPSceneFixture.scene }
            return WallpaperEditorChangeSync(role: role, dependencies: dependencies)
        }
        let appSync = sync(.app, "app"), editorSync = sync(.editor, "editor")
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost(),
                                                   sync: editorSync)
        defer { try? editor.draft.discard(); editor.window.close() } // The isolated tests' draft.
        var steps: [AppProcessChannel.OverlayStep] = []
        editorSync.onAppOverlay = { _, actionName, step in
            steps.append(step)
            editor.adoptSavedOverlay(actionName: actionName, step: step)
        }
        appSync.start()
        editorSync.start()
        defer { appSync.stop(); editorSync.stop() }
        let resources = FakeSceneEditResources(folder: wallpaper.wallpaperDirectory, identity: identity,
                                               assets: EditorAssetStore(directory: fixture.root.appending(path: "assets")))
        let service = HeadlessSceneEditService(dependencies: .init(
            store: store, center: NotificationCenter(), resources: { _ in resources },
            announce: { folder, name, step in
                appSync.appOverlayDidSave(folder: folder, actionName: name, step: step)
            }))
        let document = try service.document(for: fixture.wallpaper)
        let undoManager = editor.session.undoManager
        let name = HeadlessSceneDocument.defaultActionName
        // The window groups its undo steps by event: each message is one.
        func nextEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

        _ = try document.apply([edit(["op": "set_alpha", "layer": 4, "alpha": 0.25])], actionName: nil)
        nextEvent()
        let edited = document.session.overlay
        XCTAssertEqual(editor.session.overlay, edited)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
        XCTAssertEqual(undoManager.undoActionName, name)

        XCTAssertTrue(document.undo())
        nextEvent()
        XCTAssertEqual(editor.session.overlay, document.session.overlay, "the window shows the client's Undo")
        XCTAssertFalse(undoManager.canUndo, "the window undid the step instead of taking the Undo as one of its own")
        XCTAssertTrue(undoManager.canRedo)
        XCTAssertEqual(undoManager.redoActionName, name)

        XCTAssertTrue(document.redo())
        nextEvent()
        XCTAssertEqual(editor.session.overlay, edited, "the window shows the client's Redo")
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertFalse(undoManager.canRedo)
        XCTAssertEqual(undoManager.undoActionName, name)
        XCTAssertEqual(steps, [.edit, .undo, .redo])

        // One step in the window: one Undo there goes back to the start.
        editor.session.undo()
        XCTAssertFalse(undoManager.canUndo, "exactly one MCP Edit step")
        XCTAssertTrue(editor.session.overlay.isEmpty)
        XCTAssertTrue(try store.overlay(for: identity.rawValue).isEmpty, "Undo in the window goes into the draft")
    }

    /// A client's Undo the window can't follow (the user's own step is on top) is taken as a step,
    /// and the user's step stays.
    func testTheClientsUndoUnderTheUsersStepIsTakenAsAStep() throws {
        let wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture.folder, hiding: []))
        let identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
        let store = SceneEditOverlayFiles.draftStore
        let editor = try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost())
        defer { try? editor.draft.discard(); editor.window.close() } // The isolated tests' draft.
        func nextEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        editor.session.setValue(.number(0.5), for: "alpha", of: 5, actionName: "Opacity")
        nextEvent()
        // The app saved an overlay the window's Undo wouldn't give (as after the client's Undo of an
        // edit the window never saw).
        var stored = editor.session.overlay
        let other = SceneEditSession(outline: try SceneOutline(sceneData: MCPSceneFixture.scene), overlay: stored)
        other.setValue(.number(0.75), for: "alpha", of: 4, actionName: "Opacity")
        stored = other.overlay
        try store.saveDraft(stored, for: identity.rawValue)
        editor.adoptSavedOverlay(actionName: "Opacity", step: .undo)
        nextEvent()
        XCTAssertEqual(editor.session.overlay, stored)
        XCTAssertEqual(editor.session.undoManager.undoActionName, "Opacity")
        editor.session.undo()
        XCTAssertEqual(editor.session.overlay.field("alpha", of: 5), .number(0.5), "the user's step stays")
    }
}
