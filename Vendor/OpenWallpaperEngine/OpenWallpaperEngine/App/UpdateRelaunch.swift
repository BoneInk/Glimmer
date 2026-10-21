import Cocoa

/// Saves the UI before Sparkle relaunches for an update and restores it in the new version
/// (`UpdateRelaunchState`).
extension AppDelegate {
    func captureUpdateRelaunchState() -> UpdateRelaunchState {
        UpdateRelaunchState(
            mainWindowOpen: mainWindowController.window?.isVisible == true,
            tab: contentViewModel.navigation.topTabBarSelection,
            selectedWallpapers: Array(contentViewModel.library.selectedWallpapers).sorted { $0.path < $1.path },
            settingsOpen: settingsWindow?.isVisible == true,
            settingsPage: settingsNavigation.tab.rawValue,
            settingsFrame: settingsWindow?.frameDescriptor,
            paused: wallpaperViewModel.playRate == 0)
    }

    /// Restores a state saved before an update relaunch. Returns whether there was one, in which
    /// case the launch shows exactly what it describes and nothing else.
    @discardableResult
    func restoreUpdateRelaunchState(from defaults: UserDefaults = .app) -> Bool {
        guard let state = UpdateRelaunchState.take(from: defaults) else { return false }
        OWELog.info(.app, "Restoring the UI after an update relaunch")
        contentViewModel.navigation.topTabBarSelection = state.tab
        contentViewModel.library.selectedWallpapers = Set(state.selectedWallpapers)
        if state.paused { wallpaperViewModel.playRate = 0 }
        if state.settingsOpen {
            if let tab = SettingsTab(rawValue: state.settingsPage) { settingsNavigation.show(tab) }
            if let frame = state.settingsFrame {
                settingsWindow.setFrame(from: frame)
            } else {
                settingsWindow.center()
            }
            settingsWindow.orderFront(nil)
        }
        // The main window's frame is autosaved ("MainWindow").
        if state.mainWindowOpen { mainWindowController.window?.orderFront(nil) }
        if state.mainWindowOpen || state.settingsOpen { NSApp.activate(ignoringOtherApps: true) }
        return true
    }
}
