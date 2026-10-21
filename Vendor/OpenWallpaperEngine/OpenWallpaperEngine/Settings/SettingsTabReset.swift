import Foundation

/// "Restore Defaults" for one settings tab: its global settings (`SettingsTab.fields`) and the
/// preferences it shows that are stored outside them.
@MainActor
enum SettingsTabReset {
    /// The `UserDefaults.app` preferences a tab shows, removed on reset so they read as default.
    /// (`SteamCmdInstaller.autoInstallKey` and `WallpaperEngineAssetsService.autoInstallKey` for
    /// Assets, `WhatsNew.hidesReleaseNotesKey` and `AppUpdater.receivesBetaUpdatesKey` for Updates.)
    /// Every `@AppStorage` key a Settings view uses is here or in `nonSettingViewKeys`.
    nonisolated static func preferenceKeys(of tab: SettingsTab) -> [String] {
        switch tab {
        case .optimizations: return ["ReclaimOriginalPackages"]
        case .assets: return ["InstallSteamCmdAutomatically", "InstallsWallpaperEngineAssetsAfterLogin"]
        case .updates: return ["HidesReleaseNotesAfterUpdate", "ReceiveBetaUpdates"]
        default: return []
        }
    }

    /// Resets `tab` in `viewModel` and `defaults`. Updates also go back to updating
    /// automatically, as a new install does. General's Screen Saver Same as Wallpaper, read from
    /// `screenSaver`'s selection, goes back on: whatever was set as the screen saver goes.
    static func reset(_ tab: SettingsTab, viewModel: GlobalSettingsViewModel, defaults: UserDefaults,
                      updater: AppUpdater?, screenSaver: ScreenSaverSelectionService? = nil) {
        let reset = tab.resetting(viewModel.settings)
        if reset != viewModel.settings { viewModel.settings = reset }
        for key in preferenceKeys(of: tab) { defaults.removeObject(forKey: key) }
        if tab == .general { screenSaver?.setFollowsDesktop(true) }
        if tab == .updates, let updater, updater.isEnabled {
            updater.automaticallyChecksForUpdates = true
            updater.updatesAutomatically = true
            updater.objectWillChange.send()
        }
    }

    /// Every preference "Reset Config" removes: all tabs' keys.
    nonisolated static var allPreferenceKeys: [String] { SettingsTab.allCases.flatMap(preferenceKeys(of:)) }

    /// `UserDefaults` keys Settings views use that are view state, not settings (a disclosure
    /// that remembers being open), so no reset touches them. The library folder
    /// (`CustomWallpapersDirectory`) has its own "Use Default Location".
    nonisolated static let nonSettingViewKeys: Set<String> = ["ShowsKeyboardShortcuts"]

    /// "Reset Config": every tab's settings and preferences back to their defaults. The library,
    /// playlists, history and window state are not settings and stay.
    static func resetAll(viewModel: GlobalSettingsViewModel, defaults: UserDefaults, updater: AppUpdater?,
                         screenSaver: ScreenSaverSelectionService? = nil) {
        for tab in SettingsTab.allCases {
            reset(tab, viewModel: viewModel, defaults: defaults, updater: updater, screenSaver: screenSaver)
        }
    }

    /// Whether anything `tab` shows differs from its default (Screen Saver Same as Wallpaper off
    /// counts for General).
    static func hasChanges(_ tab: SettingsTab, settings: GlobalSettings, defaults: UserDefaults,
                           screenSaver: ScreenSaverSelectionService? = nil) -> Bool {
        tab.fields.contains { $0.isChanged(settings) }
            || preferenceKeys(of: tab).contains { defaults.object(forKey: $0) != nil }
            || tab == .general && screenSaver?.followsDesktop == false
    }
}
