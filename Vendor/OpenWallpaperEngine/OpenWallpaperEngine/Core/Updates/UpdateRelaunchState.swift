import Foundation

/// What the user had open when Sparkle relaunched the app to install an update, restored once by
/// the new version. Wallpapers per display, playlists and settings persist on their own; this is
/// the UI around them. A relaunch into the menu bar only (`mainWindowOpen` and `settingsOpen`
/// false) opens no window.
struct UpdateRelaunchState: Codable, Equatable {
    static let defaultsKey = "UpdateRelaunchState"

    var mainWindowOpen: Bool
    /// `ContentNavigation.topTabBarSelection`.
    var tab: Int
    var selectedWallpapers: [URL]
    var settingsOpen: Bool
    /// `GlobalSettingsViewModel.selection`.
    var settingsPage: Int
    /// `NSWindow.frameDescriptor` of the Settings window, which has no autosave name.
    var settingsFrame: String?
    /// Playback paused from the menu bar (not by a display rule, which re-evaluates by itself).
    var paused: Bool

    func save(to defaults: UserDefaults) {
        do {
            defaults.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            OWELog.error(.app, "Could not save the UI state for the update relaunch: \(error)")
        }
    }

    /// The saved state, removed so it applies to one launch only.
    static func take(from defaults: UserDefaults) -> UpdateRelaunchState? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        do {
            return try JSONDecoder().decode(UpdateRelaunchState.self, from: data)
        } catch {
            OWELog.error(.app, "Ignoring an unreadable update relaunch state: \(error)")
            return nil
        }
    }
}
