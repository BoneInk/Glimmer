import Observation

/// The main window's alerts, sheets and confirmations, and what they are about.
@MainActor @Observable
final class ContentPresentation {
    var isDisplaySettingsReveal = false

    var importAlertPresented = false
    var importAlertError: WPImportError? = nil

    var deletionAlertPresented = false
    var deletionAlertError: WallpaperDeletion.Failure? = nil

    /// The Workshop collection and Steam library imports (Installed's Add menu, the Workshop tab).
    var isCollectionImportPresented = false
    var isSteamLibraryImportPresented = false

    /// The wallpaper whose unsubscribe is being confirmed.
    var hoveredWallpaper: WEWallpaper?
    var isUnsubscribeConfirming = false
    /// Unsubscribing the Installed tab's selection.
    var isBatchUnsubscribeConfirming = false

    /// The Installed folder being named (Create Folder, Rename) and the one whose removal is
    /// being confirmed.
    var folderNamePrompt: InstalledFolderPrompt?
    var folderRemoval: InstalledFolder?

    func alertImportModal(which error: WPImportError) {
        importAlertError = error
        importAlertPresented = true
    }
}
