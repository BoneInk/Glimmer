//
//  Status.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/8.
//

import Cocoa

extension AppDelegate {
    @objc func mute() {
        self.wallpaperViewModel.playVolume = 0
    }

    @objc func unmute() {
        self.wallpaperViewModel.playVolume = self.wallpaperViewModel.lastPlayVolume == 0 ? 1 : self.wallpaperViewModel.lastPlayVolume
    }

    @objc func pause() {
        self.wallpaperViewModel.playRate = 0
    }

    /// Resume or Play: unpauses, and loads the wallpapers again when they are stopped.
    @objc func resume() {
        videoMemoryWatch.userResumed()
        self.wallpaperViewModel.resumeWallpapers()
    }

    @objc func browseWorkshop() {
        // Change tab selection to `Workshop`
        self.contentViewModel.navigation.topTabBarSelection = 1
        openMainWindow()
    }

    @objc func openSupportWebpage() {
        NSWorkspace.shared.open(URL(string: "https://github.com/deepratna-awale/open-wallpaper-engine-mac/wiki/Troubleshooting")!)
    }

    @objc func selectRecentWallpaper(_ sender: NSMenuItem) {
        guard let wallpaper = sender.representedObject as? WEWallpaper else { return }
        wallpaperViewModel.apply(wallpaper)
    }

    func buildRecentWallpapersMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Recent Wallpapers"))
        let recents = wallpaperViewModel.availableRecentWallpapers()

        if recents.isEmpty {
            menu.addItem(NSMenuItem(title: String(localized: "No recent wallpapers"), action: nil, keyEquivalent: ""))
        } else {
            for wallpaper in recents {
                let title = wallpaper.project.displayTitle
                let type = LocalizedLabels.wallpaperType(wallpaper.project.type)
                let itemTitle = type.isEmpty ? title
                    : String(localized: "\(title) (\(type))", comment: "Recent Wallpapers menu item: a wallpaper's title and type")
                let item = NSMenuItem(title: itemTitle, action: #selector(selectRecentWallpaper(_:)), keyEquivalent: "")
                item.representedObject = wallpaper
                item.target = self
                menu.addItem(item)
            }
        }

        return menu
    }

    func setStatusMenu() {
        // Recent Wallpapers Submenu
        let recentWallpapersMenuItem = NSMenuItem(title: String(localized: "Recent Wallpapers"), action: nil, keyEquivalent: "")
        recentWallpapersMenuItem.identifier = Self.recentWallpapersMenuItem
        recentWallpapersMenuItem.submenu = buildRecentWallpapersMenu()

        let menu = NSMenu()
        menu.delegate = self
        menu.items = Self.statusMenuItems(recentWallpapers: recentWallpapersMenuItem, assetsMissing: assets.isMissing)

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem.menu = menu

        if let button = self.statusItem.button {
            if let image = NSImage(named: "OWEStatusIcon") {
                image.isTemplate = true  // white on dark menu bars, black on light ones
                button.image = image
                button.imageScaling = .scaleProportionallyDown
            } else {
                button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: nil)
            }
            button.setAccessibilityLabel(String(localized: "Open Wallpaper Engine"))
        }
        showStoppedState()
    }
}

extension AppDelegate {
    /// The status menu's items. Items that are also in the menu bar use the same shortcuts
    /// (`AppShortcut`), which work there; the status menu shows them for reference.
    static func statusMenuItems(recentWallpapers: NSMenuItem, assetsMissing: Bool) -> [NSMenuItem] {
        func item(_ title: LocalizedStringResource, _ systemImage: String, _ action: Selector,
                  _ shortcut: AppShortcut.Name? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: String(localized: title), systemImage: systemImage, action: action, keyEquivalent: "")
            if let shortcut { item.use(AppShortcut[shortcut]) }
            return item
        }
        let quit = item("Quit", "power", #selector(AppTermination.quit(_:)), .quit)
        quit.target = AppTermination.shared
        let setUpAssets = item("Set Up Assets…", "shippingbox", #selector(openAssetsSettings))
        setUpAssets.identifier = setUpAssetsMenuItem
        setUpAssets.isHidden = !assetsMissing
        return [
            item("Show Open Wallpaper Engine", "photo", #selector(openMainWindow), .wallpaperExplorer),
            recentWallpapers,
            .separator(),
            setUpAssets,
            item("Browse Workshop", "globe", #selector(browseWorkshop), .workshop),
            item("Send Android Exports over Wi-Fi…", "wifi", #selector(showAndroidWiFiShare)),
            item("Settings", "gearshape.fill", #selector(openSettingsWindow), .settings),
            item("Check for Updates…", "arrow.down.circle", #selector(checkForUpdates), .checkForUpdates),
            .separator(),
            item("Support & FAQ", "person.fill.questionmark", #selector(openSupportWebpage)),
            .separator(),
            item("Mute", "speaker.slash.fill", #selector(toggleMuteWallpapers), .muteUnmute),
            item("Pause", "pause.fill", #selector(togglePauseWallpapers), .pauseResume),
            item("Stop Wallpapers", "stop.fill", #selector(toggleStopWallpapers)),
            item("Paused: video memory is full", "memorychip", #selector(videoMemoryPauseNotice)),
            item("Next Wallpaper", "forward.fill", #selector(nextWallpaper), .nextWallpaper),
            item("Previous Wallpaper", "backward.fill", #selector(previousWallpaper), .previousWallpaper),
            item("Take Screenshot", "camera", #selector(takeScreenshot)),
            quit,
        ]
    }
}

// MARK: - NSMenuDelegate — refresh Recent Wallpapers on menu open

extension AppDelegate: NSMenuDelegate {
    static let setUpAssetsMenuItem = NSUserInterfaceItemIdentifier("setUpAssets")
    static let recentWallpapersMenuItem = NSUserInterfaceItemIdentifier("recentWallpapers")

    func menuWillOpen(_ menu: NSMenu) {
        // Offered only while scenes are missing their assets.
        assets.refresh()
        menu.items.first { $0.identifier == Self.setUpAssetsMenuItem }?.isHidden = !assets.isMissing
        // Update the Recent Wallpapers submenu each time the status bar menu opens
        if let recentItem = menu.items.first(where: { $0.identifier == Self.recentWallpapersMenuItem }) {
            recentItem.submenu = buildRecentWallpapersMenu()
        }
    }
}
