import Foundation

/// What the scenes of a `WallpaperViewModel` borrow from the process that runs them: the global
/// settings and the SceneScript services. Open Wallpaper Engine's are its delegate's; the
/// Wallpaper Editor's process has its own (`WallpaperEditorAppDelegate`), so drawing its canvas
/// never starts the main app's.
@MainActor
struct SceneWallpaperHost {
    let settings: GlobalSettingsViewModel
    let scriptServices: SceneScriptServices?
}
