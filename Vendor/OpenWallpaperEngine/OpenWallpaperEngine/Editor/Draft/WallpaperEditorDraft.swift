import Foundation
import OWESceneEditing

/// The Wallpaper Editor's draft of one wallpaper: everything the editor changed and File › Save
/// hasn't saved yet. Nothing that runs the wallpaper sees it (the displays, the screen saver,
/// playlists, MCP readers of the wallpaper); only the editor's canvas runs it
/// (`WallpaperPropertyScope.editorDraft`). It has two halves, each kept on disk as it changes, so a
/// crash or a quit without asking leaves it for the next time the wallpaper is opened:
///
/// - the edit overlay as edited (`SceneEditDraftStore`: `<editor>/Drafts/<identity>.json`, there
///   only while it differs from the saved overlay);
/// - the user properties the editor's Details panel set (the isolated store
///   `WallpaperPropertyScope.editorDraft` in the defaults, started from the shared store's).
///
/// `commit()` (File › Save) makes both the wallpaper's own: the overlay the saved one, the
/// properties the shared store's. `discard()` (Don't Save, Discard) drops both.
@MainActor
struct WallpaperEditorDraft {
    let overlayIdentity: WallpaperSettingsIdentity
    let store: SceneEditDraftStore
    /// The wallpaper's shared user properties, which the draft's are measured against and saved
    /// into; nil when the draft has no properties (a headless edit session in tests).
    private let shared: WallpaperPropertyTargets?
    private let defaults: UserDefaults
    private let services: WallpaperServices

    init(overlayIdentity: WallpaperSettingsIdentity, properties: WallpaperPropertyTargets?,
         store: SceneEditDraftStore = SceneEditOverlayFiles.draftStore,
         defaults: UserDefaults = .app, services: WallpaperServices = .shared) {
        self.overlayIdentity = overlayIdentity
        self.store = store
        shared = properties?.scoped([.shared])
        self.defaults = defaults
        self.services = services
    }

    /// The editor's draft of `wallpaper`.
    init(wallpaper: WEWallpaper, store: SceneEditDraftStore = SceneEditOverlayFiles.draftStore,
         defaults: UserDefaults = .app, services: WallpaperServices = .shared) {
        self.init(overlayIdentity: WallpaperSettingsIdentity.resolve(directory: wallpaper.wallpaperDirectory, defaults: defaults),
                  properties: WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [.shared]),
                  store: store, defaults: defaults, services: services)
    }

    /// The draft's own store of user properties.
    var draftProperties: WallpaperPropertyTargets? { shared?.scoped([.editorDraft]) }

    // MARK: State

    /// Whether anything File › Save would save is left: an overlay draft, or user properties that
    /// differ from the shared ones.
    var hasUnsavedChanges: Bool { store.hasDraft(for: overlayIdentity.rawValue) || propertiesDiffer }

    /// The overlay as last saved; empty when it can't be read (logged).
    var savedOverlay: SceneEditOverlay {
        do {
            return try store.savedOverlay(for: overlayIdentity.rawValue)
        } catch {
            OWELog.error(.scene, "The saved editor overlay of \(overlayIdentity.rawValue) can't be read: \(error)")
            return SceneEditOverlay()
        }
    }

    /// Keeps `overlay` as the draft (the saved overlay itself: no draft).
    func saveOverlay(_ overlay: SceneEditOverlay) throws {
        try store.saveDraft(overlay, for: overlayIdentity.rawValue)
    }

    // MARK: User properties

    /// Whether the draft's store of properties exists (the editor started it, and didn't end it).
    var hasPropertyDraft: Bool {
        guard let draftProperties else { return false }
        return defaults.object(forKey: draftProperties.identity.key(.userProperties, scope: .editorDraft)) != nil
    }

    /// The shared store's user properties, which Revert to Saved goes back to.
    var savedPropertyValues: [String: String] {
        guard let shared else { return [:] }
        return WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: Self.values(of: shared, defaults: defaults))
    }

    /// Whether the draft's user properties differ from the shared ones (the Scene Edit / Export
    /// window's layer edits, which the shared store also holds, aren't the editor's).
    var propertiesDiffer: Bool {
        guard hasPropertyDraft, let draftProperties else { return false }
        let draft = WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: Self.values(of: draftProperties, defaults: defaults))
        return draft != savedPropertyValues
    }

    /// Starts the draft's store of properties: kept as it is when `resuming` one left behind, else
    /// a copy of the shared store's. The canvas's running store takes them.
    func startProperties(resuming: Bool) {
        guard let draftProperties else { return }
        if !(resuming && hasPropertyDraft) {
            removeProperties()
            draftProperties.identity.seed(.editorDraft, defaults: defaults)
        }
        services.setUserProperties(Self.values(of: draftProperties, defaults: defaults),
                                   wallpaper: draftProperties.runtimeKeys[0], replacing: true)
    }

    /// Drops the draft's store of properties (the editor's window closed with nothing unsaved).
    func endProperties() {
        guard let draftProperties else { return }
        removeProperties()
        services.setUserProperties([:], wallpaper: draftProperties.runtimeKeys[0], replacing: true)
    }

    private func removeProperties() {
        guard let draftProperties else { return }
        for family in WallpaperSettingsIdentity.Family.allCases {
            defaults.removeObject(forKey: draftProperties.identity.key(family, scope: .editorDraft))
        }
    }

    private static func values(of targets: WallpaperPropertyTargets, defaults: UserDefaults) -> [String: String] {
        targets.identity.stored(.userProperties, scope: targets.scopes[0], defaults: defaults) as? [String: String] ?? [:]
    }

    // MARK: Saving

    /// File › Save: the overlay draft becomes the saved overlay, and the draft's user properties
    /// the shared store's (its Scene Edit / Export layer edits kept), which the running wallpapers
    /// take. Returns the overlay saved; nil when only properties (or nothing) changed. The draft's
    /// store of properties stays, equal to the shared one, for the window to go on editing.
    @discardableResult
    func commit() throws -> SceneEditOverlay? {
        let overlay = try store.commit(for: overlayIdentity.rawValue)
        if propertiesDiffer, let shared, let draftProperties {
            let draft = WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: Self.values(of: draftProperties, defaults: defaults))
            let saved = WallpaperPropertyReset.sceneInspectorEdits(in: Self.values(of: shared, defaults: defaults))
                .merging(draft) { _, new in new }
            shared.save(saved, defaults: defaults)
            services.setUserProperties(saved, wallpaper: shared.runtimeKeys[0], replacing: true)
            OWELog.info(.scene, "Saved the Wallpaper Editor's user properties of \(overlayIdentity.rawValue)")
        }
        if overlay != nil { OWELog.info(.scene, "Saved the Wallpaper Editor's draft of \(overlayIdentity.rawValue)") }
        return overlay
    }

    /// Don't Save, or Discard: both halves go; the wallpaper keeps what was saved.
    func discard() throws {
        try store.discard(for: overlayIdentity.rawValue)
        endProperties()
    }
}
