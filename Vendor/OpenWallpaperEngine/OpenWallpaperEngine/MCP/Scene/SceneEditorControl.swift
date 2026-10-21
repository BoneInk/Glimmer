import AppKit
import Foundation
import OWEControlProtocol
import OWEEditor
import OWESceneEditing

/// What the scene requests do outside the edit session: the editors' windows, the running
/// particle systems, the library, and the depth map plugin. The app (`AppSceneEditorControl`), or
/// a fake in tests.
@MainActor
protocol SceneEditorControl: AnyObject {
    /// Opens Scene Edit / Export on the wallpaper in `mode` (its tab).
    func showSceneEditor(_ wallpaper: ControlWallpaper, mode: SceneInspectorMode) throws
    /// Closes Scene Edit / Export; false when it wasn't open.
    func closeSceneEditor() -> Bool
    /// Asks the Wallpaper Editor to close the wallpaper's window; false when the editor doesn't run.
    func closeWallpaperEditor(_ wallpaper: ControlWallpaper) -> Bool
    /// Plays, pauses or seeks the timeline of the wallpaper's Wallpaper Editor window; false when
    /// the editor doesn't run.
    func controlTimeline(_ wallpaper: ControlWallpaper, command: String, seconds: Double?) -> Bool
    /// Starts the particle system `layer` again: in the Wallpaper Editor's open window of the
    /// wallpaper (the draft it runs), else on the displays running it. True for the window.
    func restartParticles(_ document: HeadlessSceneDocument, layer: Int) async -> Bool
    /// Save as New Wallpaper; returns the new wallpaper's folder.
    func saveAsNewWallpaper(_ document: HeadlessSceneDocument, title: String) throws -> URL
    /// Whether Depth Map Generation is installed (Settings › Plugins).
    var isDepthMapPluginInstalled: Bool { get }
}

/// The app's side: its windows, the Wallpaper Editor's process, the library.
@MainActor
final class AppSceneEditorControl: SceneEditorControl {
    private unowned let app: AppDelegate
    private let model: AppControlModel

    init(app: AppDelegate, model: AppControlModel) {
        self.app = app
        self.model = model
    }

    func showSceneEditor(_ wallpaper: ControlWallpaper, mode: SceneInspectorMode) throws {
        guard let found = model.find(wallpaper) else { throw AppControlModel.missing(wallpaper) }
        app.showSceneInspector(for: found, scopes: model.scopes(of: found), mode: mode)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSceneEditor() -> Bool {
        guard let window = app.sceneInspectorWindow, window.isVisible else { return false }
        window.close()
        return true
    }

    func closeWallpaperEditor(_ wallpaper: ControlWallpaper) -> Bool {
        guard let found = model.find(wallpaper) else { return false }
        return app.wallpaperEditorLauncher.close(found.settingsDirectory)
    }

    func controlTimeline(_ wallpaper: ControlWallpaper, command: String, seconds: Double?) -> Bool {
        guard let found = model.find(wallpaper) else { return false }
        return app.wallpaperEditorLauncher.controlTimeline(found.settingsDirectory, command: command, seconds: seconds)
    }

    func restartParticles(_ document: HeadlessSceneDocument, layer: Int) async -> Bool {
        if let found = model.find(document.wallpaper),
           await app.wallpaperEditorLauncher.restartParticles(found.settingsDirectory, layers: [layer]) { return true }
        // No window: the displays build the system again from nothing, as saved (the draft's
        // particle documents are the editor's canvas's alone); the rest of the scene keeps running.
        SceneEditOverlayFiles.postParticles(document.draft.savedOverlay, wallpaperDirectory: document.resources.folder,
                                            objectIDs: [layer])
        return false
    }

    func saveAsNewWallpaper(_ document: HeadlessSceneDocument, title: String) throws -> URL {
        guard let found = model.find(document.wallpaper) else { throw AppControlModel.missing(document.wallpaper) }
        let folder = try LocalWallpaperSave.save(found, overlay: document.session.overlay,
                                                 assetsDirectory: document.resources.assetStore.directory, title: title)
        app.contentViewModel.refresh()
        return folder
    }

    var isDepthMapPluginInstalled: Bool { DepthMapPlugin.generator.isInstalled }
}
