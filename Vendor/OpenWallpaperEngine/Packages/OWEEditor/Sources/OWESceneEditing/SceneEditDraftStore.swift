import Foundation

/// The Wallpaper Editor's draft of a wallpaper's edits: the overlay as edited but not saved yet,
/// kept apart from the wallpaper's saved overlay (`saved`) so nothing running the wallpaper sees
/// it until File › Save. Drafts are `Drafts/<identity>.json` in the saved overlays' folder, and a
/// draft exists only while it differs from the saved overlay: an edit that leads back to it (an
/// Undo, Revert to Saved) removes the file, as Save and Don't Save do. A draft left behind (the
/// editor quit without asking, or crashed) is still there when the wallpaper is opened again.
///
/// The edits' files (`saved.assetsDirectory`) are shared with the saved overlay: they are named by
/// their content (`EditorAssetStore`), so adding one changes nothing until an overlay names it.
public struct SceneEditDraftStore: Sendable {
    /// The wallpapers' saved overlays, which running instances read.
    public let saved: SceneEditOverlayStore
    /// The drafts, one file per wallpaper.
    public let drafts: SceneEditOverlayStore

    public init(saved: SceneEditOverlayStore) {
        self.saved = saved
        drafts = SceneEditOverlayStore(directory: saved.directory.appending(path: "Drafts", directoryHint: .isDirectory))
    }

    /// Whether the wallpaper has edits that weren't saved.
    public func hasDraft(for identity: String) -> Bool {
        FileManager.default.fileExists(atPath: drafts.fileURL(for: identity).path)
    }

    /// The saved overlay; an empty one when there is none.
    public func savedOverlay(for identity: String) throws -> SceneEditOverlay {
        try saved.overlay(for: identity) ?? SceneEditOverlay()
    }

    /// The draft alone; nil when there is none.
    public func draft(for identity: String) throws -> SceneEditOverlay? {
        try drafts.overlay(for: identity)
    }

    /// What the editor edits: the draft, else the saved overlay.
    public func overlay(for identity: String) throws -> SceneEditOverlay {
        try draft(for: identity) ?? savedOverlay(for: identity)
    }

    /// Keeps `overlay` as the draft; the same as the saved overlay removes the draft. An empty
    /// draft over a saved overlay is kept (every edit dropped, not yet saved).
    public func saveDraft(_ overlay: SceneEditOverlay, for identity: String) throws {
        guard overlay != (try savedOverlay(for: identity)) else { return try drafts.remove(identity) }
        try FileManager.default.createDirectory(at: drafts.directory, withIntermediateDirectories: true)
        try overlay.encoded().write(to: drafts.fileURL(for: identity), options: .atomic)
    }

    /// File › Save: the draft becomes the saved overlay and goes. Returns the saved overlay, nil
    /// when there was no draft (nothing changed).
    @discardableResult
    public func commit(for identity: String) throws -> SceneEditOverlay? {
        guard let draft = try draft(for: identity) else { return nil }
        try saved.save(draft, for: identity)
        try drafts.remove(identity)
        return draft
    }

    /// Don't Save, or Discard: the draft goes and the saved overlay stays.
    public func discard(for identity: String) throws {
        try drafts.remove(identity)
    }
}
