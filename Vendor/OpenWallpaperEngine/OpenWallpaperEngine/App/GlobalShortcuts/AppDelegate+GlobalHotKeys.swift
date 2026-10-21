import AppKit

/// What each hotkey action (`GlobalHotKeyAction`), and each wallpaper's or profile's hotkey, does
/// when its shortcut is pressed.
extension AppDelegate {
    /// macOS's screen saver, which "Start screensaver" opens as WE starts Windows' own.
    static let screenSaverEngineURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    func performHotKey(_ action: GlobalHotKeyAction) {
        switch action {
        case .pause: togglePauseWallpapers()
        case .stop: toggleStopWallpapers()
        case .mute: toggleMuteWallpapers()
        case .nextWallpaper: nextWallpaper()
        case .previousWallpaper: previousWallpaper()
        case .toggleRecording:
            let capture = WallpaperServices.shared.audioCapture
            capture.isRecordingEnabled.toggle()
        case .toggleIcons: toggleDesktopIcons()
        case .screenshot: takeScreenshot()
        case .startScreensaver:
            NSWorkspace.shared.openApplication(at: Self.screenSaverEngineURL, configuration: .init()) { _, error in
                if let error { OWELog.error(.app, "Starting the screen saver failed: \(error)") }
            }
        case .windowBrowser:
            NSApp.activate()
            openMainWindow()
        case .windowSettings:
            NSApp.activate()
            openSettingsWindow()
        case .windowEditor:
            guard WallpaperEditorController.canEdit(wallpaperViewModel.displayedWallpaper) else {
                OWELog.info(.app, "Wallpaper Editor hotkey: the displayed wallpaper isn't a scene")
                NSSound.beep()
                return
            }
            showWallpaperEditorForDisplayedWallpaper()
        }
    }

    /// A wallpaper's or profile's hotkey (`UserHotKey`): the wallpaper on its display, as Set as
    /// Wallpaper applies it there (one that runs code asks for trust first), or the profile.
    func performUserHotKey(_ hotKey: UserHotKey) {
        switch hotKey.target {
        case let .wallpaper(wallpaper, location):
            guard let screenId = UserHotKey.screenId(ofLocation: location, connected: wallpaperViewModel.connectedDisplays()) else {
                OWELog.info(.app, "Hotkey of \"\(hotKey.title)\": its display \(location) isn't connected")
                NSSound.beep()
                return
            }
            guard FileManager.default.fileExists(atPath: wallpaper.wallpaperDirectory.path(percentEncoded: false)) else {
                OWELog.info(.app, "Hotkey of \"\(hotKey.title)\": the wallpaper is no longer installed")
                NSSound.beep()
                return
            }
            wallpaperViewModel.apply(wallpaper, on: [screenId])
        case let .profile(name):
            if !wallpaperViewModel.displayProfiles.load(name: name) { NSSound.beep() }
        }
    }

    /// Opens Assign Hotkey for a wallpaper on a display, or for a profile (`AssignHotKeySheet`).
    func showAssignHotKey(_ target: UserHotKey.Target) {
        AssignHotKeyPresenter.present(target, hotKeys: userHotKeys) { [unowned self] recording in
            recording ? globalHotKeys.suspend() : globalHotKeys.resume()
        }
    }

    /// WE's "Hide desktop icons": the wallpaper windows move above the desktop icons, which they
    /// then cover, or back below them. Finder and its settings are left alone.
    func toggleDesktopIcons() {
        hidesDesktopIcons.toggle()
        let level = Self.wallpaperWindowLevel(hidingDesktopIcons: hidesDesktopIcons)
        for window in wallpaperWindows.values { window.level = level }
        OWELog.info(.app, "Desktop icons \(hidesDesktopIcons ? "hidden" : "shown")")
    }

    /// The wallpaper windows' level: the desktop's, below the icons, or just above the icons.
    static func wallpaperWindowLevel(hidingDesktopIcons: Bool) -> NSWindow.Level {
        hidingDesktopIcons
            ? NSWindow.Level(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)))
    }
}
