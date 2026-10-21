import Foundation

extension Notification.Name {
    /// `ScenePropertyEditing.isActive` changed.
    static let scenePropertyEditingDidChange = Notification.Name("ScenePropertyEditingDidChange")
}

/// Whether the user is editing wallpaper properties: while a window that edits them is open (the
/// main window's properties panel, Scene Edit / Export). Changes apply by their bindings' class
/// either way (`SceneBindingUpdate`); when the last window closes, each scene that took a change
/// meanwhile rebuilds once, off the main thread, to what a fresh load draws (the reconcile).
/// Owned by `WallpaperServices`; main thread.
@MainActor
final class ScenePropertyEditing {
    private var editors = 0
    /// What was last announced: an editor that goes away and comes back at once (a view rebuilt
    /// for another wallpaper) doesn't end the editing.
    private(set) var isActive = false
    /// How long editing outlasts its last window, for a view that is only being rebuilt.
    static let endDelay: TimeInterval = 0.5

    nonisolated init() {}

    /// A window that edits properties appeared; balanced by `end()`.
    func begin() {
        editors += 1
        announce()
    }

    /// A window that edits properties went away.
    func end() {
        guard editors > 0 else { return }
        editors -= 1
        guard editors == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.endDelay) { [weak self] in
            MainActor.assumeIsolated { self?.announce() }
        }
    }

    private func announce() {
        let active = editors > 0
        guard active != isActive else { return }
        isActive = active
        NotificationCenter.default.post(name: .scenePropertyEditingDidChange, object: self)
    }
}
