import SwiftUI
import AVFoundation
import OWEInspectorKit
import OWESceneEditing

extension AppDelegate {
    /// `scopes`: whose properties its edits change (`WallpaperViewModel.editedPropertyScopes`).
    /// `mode`: the mode it opens in (an MCP client's `editor_set_tab`).
    func showSceneInspector(for wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope] = [.shared],
                            mode: SceneInspectorMode = .wallpaper) {
        if let sceneInspectorWindow {
            sceneInspectorWindow.contentView = Self.sceneInspectorContent(wallpaper, scopes, mode)
            // A closed inspector (kept, not released) edits again.
            if !sceneInspectorWindow.isVisible { WallpaperServices.shared.propertyEditing.begin() }
            sceneInspectorWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Scene Edit / Export")
        // The title names the window in the Window menu; the toolbar's mode picker already shows
        // where the editor is, so the title isn't repeated beside it.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = Self.sceneInspectorContent(wallpaper, scopes, mode)
        window.center()
        // The inspector edits properties while it is open (`ScenePropertyEditing`). The window is
        // kept for the app's life, and so is this observer.
        WallpaperServices.shared.propertyEditing.begin()
        _ = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { [weak window] _ in
            MainActor.assumeIsolated {
                WallpaperServices.shared.propertyEditing.end()
                // The editor goes with the window, so an isolated mode's private instance and
                // store stop now. Showing the editor again gives the window new content.
                window?.contentView = NSView()
            }
        }
        window.makeKeyAndOrderFront(nil)
        sceneInspectorWindow = window
    }

    /// The window can't shrink below the view's minimum size: a smaller window laid the columns
    /// out at their minimum and centred them, pushing their tops under the toolbar.
    private static func sceneInspectorContent(_ wallpaper: WEWallpaper, _ scopes: [WallpaperPropertyScope],
                                              _ mode: SceneInspectorMode) -> NSView {
        let view = NSHostingView(rootView: SceneInspectorView(wallpaper: wallpaper, scopes: scopes, initialMode: mode)
            .appAccentTint())
        view.sizingOptions = [.minSize]
        return view
    }
}
