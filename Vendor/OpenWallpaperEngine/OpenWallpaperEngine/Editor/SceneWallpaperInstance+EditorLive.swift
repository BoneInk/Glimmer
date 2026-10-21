import Foundation
import OWESceneEditing

/// The Wallpaper Editor's live channel (editor-plan notes §3): a layer's transform, opacity and
/// colour and an effect's visibility and constants follow the editor every frame, without reading
/// the scene again. The loaded scene was read with one overlay (`loadedEditOverlay`); the editor's
/// latest is drawn as the difference (`SceneEditLiveValues`), which a later read folds in.
extension SceneWallpaperInstance {
    /// Whether the editor's change of the wallpaper in `folder` is this instance's. By path: the
    /// Wallpaper Editor's process names the folder in a message (`WallpaperEditorChangeSync`), so
    /// its URL may differ from this instance's in a trailing slash.
    func runsWallpaper(in folder: URL?) -> Bool {
        guard let folder else { return false }
        return folder.standardizedFileURL.path == viewModel.currentWallpaper.wallpaperDirectory.standardizedFileURL.path
    }

    /// Whether this is the Wallpaper Editor's canvas, which runs the editor's draft
    /// (`WallpaperPropertyScope.editorDraft`): it takes the draft's changes, every other instance
    /// only the saved overlay's.
    var runsEditorDraft: Bool { key.properties == .editorDraft }

    /// Takes the editor's overlay; true when the renderer draws it live (no reload needed).
    func applyEditorEdits(overlay: SceneEditOverlay?, base: SceneOutline?) -> Bool {
        guard let overlay, let base else { return false }
        editorEdits = (overlay, base)
        guard let live = editorLiveValues() else { return false }
        renderLoop.perform { $0.setEditorLiveValues(live) }
        return true
    }

    /// The editor's latest edits as live values over the loaded scene; empty without any, nil
    /// when they need the scene read again.
    func editorLiveValues() -> SceneEditLiveValues? {
        guard let edits = editorEdits else { return SceneEditLiveValues() }
        let built = viewModel.loadedEditOverlay ?? SceneEditOverlay()
        return SceneEditLiveValues.make(built: built, current: edits.overlay, base: edits.base)
    }
}
