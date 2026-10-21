import AppKit

/// The actions of the menu bar's app items (`makeMainMenu`) and the status menu.
extension AppDelegate {
    static let helpURL = URL(string: "https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki")!
    static let securityReportURL = URL(string: "https://github.com/deepratna-awale/open-wallpaper-engine-mac/security")!

    @objc func togglePauseWallpapers() {
        if wallpaperViewModel.playRate == 0 || videoMemoryWatch.exhausted || wallpaperViewModel.isStopped {
            resume()
        } else {
            pause()
        }
    }

    /// The status line under Pause/Resume while video memory holds the wallpapers paused; never
    /// enabled (`validateMenuItem`).
    @objc func videoMemoryPauseNotice() {}

    @objc func toggleMuteWallpapers() {
        if wallpaperViewModel.playVolume == 0 { unmute() } else { mute() }
    }

    /// The next playlist wallpaper, or a random one from the Installed list as shown.
    @objc func nextWallpaper() {
        wallpaperViewModel.stepToNextWallpaper(shown: contentViewModel.library.autoRefreshWallpapers)
    }

    /// The previous playlist wallpaper, or the display's previous one.
    @objc func previousWallpaper() {
        wallpaperViewModel.stepToPreviousWallpaper()
    }

    @objc func showSceneInspectorForDisplayedWallpaper() {
        let wallpaper = wallpaperViewModel.displayedWallpaper
        showSceneInspector(for: wallpaper, scopes: wallpaperViewModel.editedPropertyScopes(of: wallpaper))
    }

    /// Window › Wallpaper Editor: the displayed wallpaper in its editor; scene wallpapers only
    /// (`validateMenuItem`).
    @objc func showWallpaperEditorForDisplayedWallpaper() {
        showWallpaperEditor(for: wallpaperViewModel.displayedWallpaper)
    }

    @objc func showInstalledTab() { showLibraryTab(0) }
    @objc func showDownloadsTab() { showLibraryTab(2) }
    @objc func showPlaylistsTab() { showLibraryTab(3) }

    private func showLibraryTab(_ tab: Int) {
        contentViewModel.navigation.topTabBarSelection = tab
        openMainWindow()
    }

    /// Edit › Find: the search field of the settings window when it's in front, otherwise the
    /// library's.
    @objc func focusSearch() {
        if settingsWindow.isKeyWindow {
            settingsNavigation.focusesSearch = true
            return
        }
        if contentViewModel.navigation.topTabBarSelection > 1 { contentViewModel.navigation.topTabBarSelection = 0 }
        openMainWindow()
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.mainWindowController.window else { return }
            if let field = Self.searchField(in: window) { window.makeFirstResponder(field) }
        }
    }

    /// The tab's toolbar search field (`ToolbarSearchField`), found in the window's views, which
    /// include the toolbar's.
    private static func searchField(in window: NSWindow) -> NSSearchField? {
        func find(_ view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField, field.identifier == ToolbarSearchField.identifier { return field }
            for subview in view.subviews { if let field = find(subview) { return field } }
            return nil
        }
        return window.contentView?.superview.flatMap(find)
    }

    @objc func openHelp() {
        NSWorkspace.shared.open(Self.helpURL)
    }

    @objc func openSecurityReport() {
        NSWorkspace.shared.open(Self.securityReportURL)
    }

    @objc func showKeyboardShortcuts() {
        openSettings(.general, anchor: SettingsAnchor.shortcuts)
    }

    @objc func showTermsOfUse() {
        LegalDocumentWindow.show(.termsOfUse)
    }

    @objc func showPrivacyPolicy() {
        LegalDocumentWindow.show(.privacyPolicy)
    }
}
