import XCTest
@testable import OWESceneEditing

/// The Wallpaper Editor's draft beside the saved overlay: the saved overlay is untouched until
/// commit, and a draft exists only while it differs from it.
final class SceneEditDraftStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SceneEditDraftStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "DraftStore-\(UUID().uuidString)")
        store = SceneEditDraftStore(saved: SceneEditOverlayStore(directory: directory))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory) // A temporary folder.
    }

    private func overlay(alpha: Double) -> SceneEditOverlay {
        var overlay = SceneEditOverlay()
        overlay.setField("alpha", to: .number(alpha), of: 4)
        return overlay
    }

    func testTheSavedOverlayStaysUntilCommit() throws {
        try store.saved.save(overlay(alpha: 0.5), for: "w")
        try store.saveDraft(overlay(alpha: 0.25), for: "w")
        XCTAssertTrue(store.hasDraft(for: "w"))
        XCTAssertEqual(try store.savedOverlay(for: "w"), overlay(alpha: 0.5), "editing leaves the saved overlay")
        XCTAssertEqual(try store.overlay(for: "w"), overlay(alpha: 0.25), "the editor reads its draft")
        XCTAssertEqual(store.drafts.directory.lastPathComponent, "Drafts")

        XCTAssertEqual(try store.commit(for: "w"), overlay(alpha: 0.25))
        XCTAssertEqual(try store.savedOverlay(for: "w"), overlay(alpha: 0.25))
        XCTAssertFalse(store.hasDraft(for: "w"))
        XCTAssertNil(try store.commit(for: "w"), "nothing left to save")
    }

    func testADraftBackAtTheSavedOverlayGoes() throws {
        try store.saved.save(overlay(alpha: 0.5), for: "w")
        try store.saveDraft(overlay(alpha: 0.25), for: "w")
        try store.saveDraft(overlay(alpha: 0.5), for: "w")
        XCTAssertFalse(store.hasDraft(for: "w"), "an Undo back to the saved edits leaves nothing unsaved")
    }

    func testDroppingEveryEditIsADraftOfItsOwn() throws {
        try store.saved.save(overlay(alpha: 0.5), for: "w")
        try store.saveDraft(SceneEditOverlay(), for: "w")
        XCTAssertTrue(store.hasDraft(for: "w"))
        XCTAssertEqual(try store.overlay(for: "w"), SceneEditOverlay())
        try store.commit(for: "w")
        XCTAssertNil(try store.saved.overlay(for: "w"), "saving no edits removes the overlay")
    }

    func testDiscardKeepsTheSavedOverlay() throws {
        try store.saved.save(overlay(alpha: 0.5), for: "w")
        try store.saveDraft(overlay(alpha: 0.25), for: "w")
        try store.discard(for: "w")
        XCTAssertFalse(store.hasDraft(for: "w"))
        XCTAssertEqual(try store.overlay(for: "w"), overlay(alpha: 0.5))
    }
}
