import XCTest
import OWEControlProtocol
import OWESceneEditing
@testable import OpenWallpaperEngine

/// The Wallpaper Editor's window edits a draft (`WallpaperEditorDraft`): the wallpaper's saved
/// overlay, which every running instance reads, is untouched until File › Save, which commits it
/// once; Save as New Wallpaper leaves it as it is; Don't Save discards the draft; a draft left
/// behind resumes; Undo stays in the draft; and the Details panel's user properties are drafted too.
@MainActor
final class WallpaperEditorDraftTests: XCTestCase {
    private var fixture: MCPSceneFixture!
    private var wallpaper: WEWallpaper!
    private var identity: WallpaperSettingsIdentity!
    /// The isolated tests' stores, which the window uses.
    private let store = SceneEditOverlayFiles.draftStore

    override func setUp() async throws {
        fixture = try MCPSceneFixture()
        wallpaper = try XCTUnwrap(InstalledLibrary.wallpaper(at: fixture.folder, hiding: []))
        identity = WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory)
    }

    override func tearDown() async throws {
        if let identity {
            try? store.discard(for: identity.rawValue) // The isolated tests' draft.
            try? store.saved.remove(identity.rawValue) // And saved overlay.
        }
        if let wallpaper { WallpaperEditorDraft(wallpaper: wallpaper).endProperties() }
        fixture?.remove()
    }

    private func editor(sync: WallpaperEditorChangeSync? = nil, resumesDraft: Bool = true) throws -> WallpaperEditorController {
        try WallpaperEditorController(wallpaper: wallpaper, host: WallpaperEditorAppDelegate.makeSceneHost(), sync: sync,
                                      resumesDraft: resumesDraft)
    }

    /// The window groups its undo steps by event: each step of a test is one.
    private func nextEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    private func savedAlpha() throws -> SceneJSONValue? {
        try store.savedOverlay(for: identity.rawValue).field("alpha", of: 4)
    }

    // MARK: Saving

    func testTheSavedOverlayIsUntouchedUntilSaveAndSaveCommitsOnce() throws {
        let messaging = MCPFakeProcessMessaging()
        let sync = WallpaperEditorChangeSync(role: .editor, dependencies: .init(
            messaging: messaging, channel: AppProcessChannel(isolationTag: "tests"), sender: "editor", store: store.saved,
            local: NotificationCenter(), defaults: .app))
        let editor = try editor(sync: sync)
        defer { editor.window.close() }
        var drafts: [Bool] = []
        let token = NotificationCenter.default.addObserver(forName: .sceneEditOverlayDidChange, object: nil, queue: nil) { [folder = fixture.folder] note in
            guard (note.userInfo?["wallpaperDirectory"] as? URL)?.path == folder.standardizedFileURL.path else { return }
            drafts.append(note.userInfo?["draft"] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        func saves() -> Int { messaging.posted.filter { $0.name.rawValue.hasSuffix("editor.overlayDidSave") }.count }

        XCTAssertFalse(editor.isEdited)
        editor.session.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")
        XCTAssertNil(try store.saved.overlay(for: identity.rawValue), "editing leaves the wallpaper's overlay")
        XCTAssertEqual(try store.draft(for: identity.rawValue)?.field("alpha", of: 4), .number(0.5), "the draft is on disk at once")
        XCTAssertTrue(editor.isEdited)
        XCTAssertTrue(editor.window.isDocumentEdited, "the close button's dot")
        XCTAssertEqual(drafts, [true], "only the canvas hears the edit")
        XCTAssertEqual(saves(), 0, "Open Wallpaper Engine hears nothing")

        try editor.saveDraft()
        XCTAssertEqual(try savedAlpha(), .number(0.5))
        XCTAssertFalse(store.hasDraft(for: identity.rawValue))
        XCTAssertFalse(editor.isEdited)
        XCTAssertFalse(editor.window.isDocumentEdited)
        XCTAssertEqual(saves(), 1, "the running instances reload once")
        XCTAssertEqual(drafts, [true, false])
        try editor.saveDraft()
        XCTAssertEqual(saves(), 1, "nothing left to save")
    }

    func testSaveAsNewLeavesTheOriginalAndItsDraftUntouched() throws {
        // Save as New Wallpaper writes into the library: a temporary one.
        let storageKey = "CustomWallpapersDirectory"
        let savedStorage = UserDefaults.app.string(forKey: storageKey)
        let library = fixture.root.appending(path: "library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        UserDefaults.app.set(library.path, forKey: storageKey)
        defer { UserDefaults.app.set(savedStorage, forKey: storageKey) }
        let editor = try editor()
        defer { editor.window.close() }
        editor.session.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")

        _ = try editor.makeServices().saveAsNewWallpaper("Fixture (Edited)")
        XCTAssertNil(try store.saved.overlay(for: identity.rawValue), "the original keeps its saved edits")
        XCTAssertEqual(try store.draft(for: identity.rawValue)?.field("alpha", of: 4), .number(0.5), "and its draft")
        XCTAssertTrue(editor.isEdited, "the window goes on editing the original's draft")
        let copies = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
        let copy = try XCTUnwrap(copies.first { FileManager.default.fileExists(atPath: $0.appending(path: "scene.json").path) })
        let scene = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: copy.appending(path: "scene.json"))) as? [String: Any])
        let objects = try XCTUnwrap(scene["objects"] as? [[String: Any]])
        XCTAssertEqual((objects.first { ($0["id"] as? NSNumber)?.intValue == 4 }?["alpha"] as? NSNumber)?.doubleValue, 0.5,
                       "the new wallpaper has the draft baked in")
    }

    // MARK: Closing

    func testDontSaveDiscardsCancelKeepsAndSaveCommits() throws {
        let editor = try editor()
        defer { editor.window.close() }
        editor.session.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")
        XCTAssertFalse(editor.resolveUnsavedChanges(.alertSecondButtonReturn), "Cancel keeps the window open")
        XCTAssertTrue(store.hasDraft(for: identity.rawValue))
        XCTAssertTrue(editor.resolveUnsavedChanges(.alertFirstButtonReturn), "Save closes once saved")
        XCTAssertEqual(try savedAlpha(), .number(0.5))

        nextEvent()
        editor.session.setValue(.number(0.25), for: "alpha", of: 4, actionName: "Opacity")
        XCTAssertTrue(editor.resolveUnsavedChanges(.alertThirdButtonReturn), "Don't Save closes")
        XCTAssertFalse(store.hasDraft(for: identity.rawValue), "and drops the draft")
        XCTAssertEqual(try savedAlpha(), .number(0.5), "the wallpaper keeps what was saved")
    }

    func testADraftLeftBehindResumesOrIsDiscarded() throws {
        let first = try editor()
        first.session.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")
        // Closed without asking (as after a crash, or an MCP client's editor_close).
        first.window.close()
        XCTAssertTrue(WallpaperEditorDraft(wallpaper: wallpaper).hasUnsavedChanges, "the editor offers Resume or Discard")

        let resumed = try editor(resumesDraft: true)
        XCTAssertEqual(resumed.session.overlay.field("alpha", of: 4), .number(0.5))
        XCTAssertTrue(resumed.isEdited)
        resumed.window.close()

        let discarded = try editor(resumesDraft: false)
        defer { discarded.window.close() }
        XCTAssertNil(discarded.session.overlay.field("alpha", of: 4))
        XCTAssertFalse(discarded.isEdited)
        XCTAssertFalse(store.hasDraft(for: identity.rawValue))
        XCTAssertNil(try store.saved.overlay(for: identity.rawValue), "nothing was ever saved")
    }

    // MARK: Undo and Revert to Saved

    func testUndoAndRevertStayInTheDraft() throws {
        let editor = try editor()
        defer { editor.window.close() }
        // One undo step per change: a synchronous test has no event loop turns to group by.
        editor.session.undoManager.groupsByEvent = false
        editor.session.setValue(.number(0.5), for: "alpha", of: 4, actionName: "Opacity")
        try editor.saveDraft()
        editor.session.setValue(.number(0.25), for: "alpha", of: 4, actionName: "Opacity")

        editor.session.undo()
        XCTAssertEqual(editor.session.overlay.field("alpha", of: 4), .number(0.5))
        XCTAssertFalse(editor.isEdited, "back at the last save")
        XCTAssertFalse(store.hasDraft(for: identity.rawValue))
        editor.session.undo()
        XCTAssertNil(editor.session.overlay.field("alpha", of: 4), "Undo goes on past the save")
        XCTAssertTrue(editor.isEdited)
        XCTAssertTrue(store.hasDraft(for: identity.rawValue), "an empty draft over saved edits")
        XCTAssertEqual(try savedAlpha(), .number(0.5), "Undo never reaches the saved overlay")

        editor.revertToSaved()
        XCTAssertEqual(editor.session.overlay.field("alpha", of: 4), .number(0.5), "Revert to Saved: the last save")
        XCTAssertFalse(editor.isEdited)
        editor.session.undo()
        XCTAssertNil(editor.session.overlay.field("alpha", of: 4), "Revert to Saved is undoable")
        XCTAssertEqual(try savedAlpha(), .number(0.5))
    }

    // MARK: User properties

    func testTheDraftsUserPropertiesReachTheSharedStoreOnlyOnSave() throws {
        let defaults = fixture.defaults
        let draft = WallpaperEditorDraft(wallpaper: wallpaper, store: fixture.draftStore, defaults: defaults)
        let shared = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared])
        let layerEdit = "_owe_scene_object_4_alpha"
        shared.save(["speed": "1", layerEdit: "0.5"], defaults: defaults)
        draft.startProperties(resuming: false)
        XCTAssertFalse(draft.propertiesDiffer)
        XCTAssertFalse(draft.hasUnsavedChanges)

        try XCTUnwrap(draft.draftProperties).save(["speed": "2", layerEdit: "0.5"], defaults: defaults)
        XCTAssertTrue(draft.propertiesDiffer)
        XCTAssertTrue(draft.hasUnsavedChanges)
        func sharedValues() -> [String: String] {
            shared.identity.stored(.userProperties, scope: .shared, defaults: defaults) as? [String: String] ?? [:]
        }
        XCTAssertEqual(sharedValues()["speed"], "1", "the displays' properties are untouched")

        // The Scene Edit / Export window changes its own layer edit meanwhile.
        shared.save(["speed": "1", layerEdit: "0.25"], defaults: defaults)
        XCTAssertNil(try draft.commit(), "no overlay to save, only properties")
        XCTAssertEqual(sharedValues(), ["speed": "2", layerEdit: "0.25"], "the draft's properties, the other window's layer edit")
        XCTAssertFalse(draft.propertiesDiffer)

        try XCTUnwrap(draft.draftProperties).save(["speed": "0.5"], defaults: defaults)
        try draft.discard()
        XCTAssertFalse(draft.hasPropertyDraft)
        XCTAssertEqual(sharedValues()["speed"], "2", "Don't Save leaves the shared store")
    }

    // MARK: The canvas

    func testOnlyAnInstanceOfTheDraftReadsTheDraft() throws {
        try store.saved.save(overlay(alpha: 0.5), for: identity.rawValue)
        try store.saveDraft(overlay(alpha: 0.25), for: identity.rawValue)
        let canvas = SceneContentLoader(wallpaper: wallpaper, propertyScope: .editorDraft, effectTranslator: nil)
        XCTAssertEqual(canvas.loadedEditOverlay?.field("alpha", of: 4), .number(0.25), "the editor's canvas runs the draft")
        let display = SceneContentLoader(wallpaper: wallpaper, effectTranslator: nil)
        XCTAssertEqual(display.loadedEditOverlay?.field("alpha", of: 4), .number(0.5), "a display runs the saved overlay")

        let preview = WallpaperViewModel(persistsWallpapers: false)
        preview.previewPropertyScope = .editorDraft
        preview.setWallpaper(wallpaper, for: preview.selectedScreenId)
        XCTAssertEqual(preview.instanceKey(for: preview.selectedScreenId).properties, .editorDraft)
        XCTAssertEqual(preview.propertyScope(for: preview.selectedScreenId), .editorDraft)
    }

    private func overlay(alpha: Double) -> SceneEditOverlay {
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(alpha), of: 4)
        return overlay
    }
}
