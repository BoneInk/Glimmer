import AppKit

/// What a launch starts, by mode (`AppLaunchMode`). `AppMain` reads it to pick the process's
/// delegate: Open Wallpaper Engine's (`AppDelegate`), which starts every main-app service, or the
/// Wallpaper Editor's (`WallpaperEditorAppDelegate`), which starts none of them. The editor never
/// creates `AppDelegate.shared`, so nothing the main app does at launch runs in its process.
struct AppLaunchPlan: Equatable {
    /// A part of the app that starts at launch.
    enum Service: CaseIterable, Hashable {
        case desktopWallpapers
        case menuBarItem
        case mainWindow
        case screenSaver
        case lockScreenPicture
        case workshopSync
        case updater
        case crashWatcher
        case safeRestart
        case globalShortcuts
        case playbackMonitors
        /// Picks up what the Wallpaper Editor's process saved (`WallpaperEditorChangeSync`).
        case editorChangeSync
        /// Editor windows and the editor's own menu, as their own app.
        case wallpaperEditorWindows
    }

    let mode: AppLaunchMode
    let services: Set<Service>
    /// The editor is a regular app (Dock icon, menu bar) while it runs; the main app manages its
    /// own (`DockPresence`).
    let activationPolicy: NSApplication.ActivationPolicy?

    static func plan(for mode: AppLaunchMode) -> AppLaunchPlan {
        switch mode {
        case .main:
            return AppLaunchPlan(mode: mode, services: Set(Service.allCases).subtracting([.wallpaperEditorWindows]),
                                 activationPolicy: nil)
        case .wallpaperEditor:
            return AppLaunchPlan(mode: mode, services: [.wallpaperEditorWindows], activationPolicy: .regular)
        }
    }

    /// The process's delegate for this plan, made only when it is the one asked for.
    @MainActor
    func makeDelegate() -> NSApplicationDelegate {
        if services.contains(.wallpaperEditorWindows), case .wallpaperEditor(let folder) = mode {
            return WallpaperEditorAppDelegate(initialFolder: folder)
        }
        return AppDelegate.shared
    }
}
