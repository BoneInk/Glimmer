import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit
import OWEInspectorKit
import OWETheming

extension AppDelegate {
    @objc func openSettingsWindow() {
        // What Cancel goes back to.
        globalSettingsViewModel.beginEditing()
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow.makeKeyAndOrderFront(nil)
    }
    
    /// Opens Settings on `tab`, scrolled to the section `anchor` names when given.
    func openSettings(_ tab: SettingsTab, anchor: String? = nil) {
        settingsNavigation.show(tab, anchor: anchor)
        openSettingsWindow()
    }

    /// Settings › Assets, where the assets scenes need are installed.
    @objc func openAssetsSettings() {
        openSettings(.assets, anchor: SettingsAnchor.assets)
    }

    /// The Settings page the Wallpaper Editor asked for.
    func openSettings(for request: AppSettingsRequest) {
        switch request {
        case .assets: openAssetsSettings()
        case .depthMaps: openSettings(.plugins, anchor: SettingsAnchor.depthMaps)
        }
    }

    /// The Workshop tab, where Steam's login form is.
    @objc func openSteamLogin() {
        contentViewModel.navigation.topTabBarSelection = 1
        openMainWindow()
    }

    /// Nothing before launch has made the window (test hosts never get there).
    @objc func openMainWindow() {
        guard let window = self.mainWindowController?.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @MainActor @objc func toggleFilter() {
        self.contentViewModel.navigation.toggleFilter()
    }

    /// Posted at most once per launch by `AudioCapturePermissionGate`, and never after
    /// "Don't Ask Again".
    @objc func audioCapturePermissionMissing() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Audio Visualizers Need Permission")
        alert.informativeText = PermissionHelper.usesSystemAudioRecording
            ? String(localized: """
            Open Wallpaper Engine needs System Audio Recording permission to read system audio \
            for audio bars and other audio-reactive wallpapers. Audio capture starts on its own once \
            the permission is granted.
            """, comment: "System Audio Recording is the name of the macOS privacy setting")
            : String(localized: """
            Open Wallpaper Engine needs Screen & System Audio Recording permission to read system audio \
            for audio bars and other audio-reactive wallpapers. Audio capture starts on its own once \
            the permission is granted.
            """, comment: "Screen & System Audio Recording is the name of the macOS privacy setting")
        alert.addButton(withTitle: String(localized: "Grant Access"))
        alert.addButton(withTitle: String(localized: "Open Permissions Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Don't Ask Again"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            PermissionHelper.grantAudioCaptureAccess { WallpaperServices.shared.recheckCapturePermission() }
        case .alertSecondButtonReturn:
            openSettings(.permissions)
        case .alertThirdButtonReturn:
            break
        default:
            GlobalSettingsViewModel.isAudioPermissionAlertDismissed = true
        }
    }
}
