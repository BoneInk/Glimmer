import Cocoa
import Combine
import SwiftUI
import AVKit
import WebKit
import OWEInspectorKit
import OWETheming

extension AppDelegate {
    /// The bare settings window: resizable to any width, with no minimum width.
    static func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsTab.toolbarFittingWidth(), height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        return window
    }

    func setSettingsWindow() {
        self.settingsWindow = Self.makeSettingsWindow()

        self.settingsWindow.delegate = self
        
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        
        toolbar.selectedItemIdentifier = settingsNavigation.tab.toolbarIdentifier
        settingsNavigation.toolbar = toolbar

        self.settingsWindow.toolbar = toolbar
        let ruleLibrary = ApplicationRuleLibrary(
            wallpapers: { [weak self] in self?.contentViewModel.library.allWallpapers ?? [] },
            playlists: { [weak self] in self?.wallpaperViewModel.playlists ?? [] },
            profiles: { [weak self] in self?.displayProfiles ?? UnavailableDisplayProfiles() })
        self.settingsWindow.contentView = NSHostingView(rootView: SettingsView()
            .environmentObject(self.globalSettingsViewModel)
            .environmentObject(settingsNavigation)
            .environment(\.applicationRuleLibrary, ruleLibrary)
            .appAccentTint())

        // A saved frame is the size and place the user left the window at; only the first open
        // gets the computed size. The frame autosaves into UserDefaults.standard, which an
        // isolated copy must not write.
        let autosaveName = "SettingsWindow"
        let isIsolated = AppStorageLocation.current.isIsolated
        let restored = !isIsolated && self.settingsWindow.setFrameUsingName(autosaveName)
        if !isIsolated { self.settingsWindow.setFrameAutosaveName(autosaveName) }
        if !restored, let screen = self.settingsWindow.screen ?? NSScreen.main {
            let size = SettingsTab.initialWindowSize(visibleFrame: screen.visibleFrame)
            self.settingsWindow.setFrame(NSRect(origin: .zero, size: size), display: false)
            self.settingsWindow.center()
        }
    }
}
