import Foundation

/// "Set as Screen Saver" from the Installed, Discover and Workshop menus, the Details panel and
/// MCP: what can be set, and setting it at once, without opening an editor.
extension ScreenSaverSelectionService {
    /// Whether `wallpaper` can be set as the screen saver now.
    enum Availability: Equatable {
        case available
        /// A web wallpaper or a WebM video: drawn live only by the Chromium engine, which isn't installed.
        case needsChromium
        /// Not one the screen saver shows; the reason is shown in its place.
        case unavailable(String)

        var isAvailable: Bool { self == .available }
    }

    /// What the screen saver can be set to: a scene or a video (MP4, M4V, MOV) drawn live by the
    /// app, and a web wallpaper or WebM video drawn live through Chromium
    /// (`ScreenSaverPlugin.liveKind`). Never an application wallpaper.
    nonisolated static func availability(of wallpaper: WEWallpaper, chromiumInstalled: Bool) -> Availability {
        if ScreenSaverPlugin.isScene(wallpaper) || ScreenSaverVideoSource.isEligible(wallpaper) { return .available }
        if ScreenSaverPlugin.isWeb(wallpaper)
            || ScreenSaverPlugin.isWebMVideo(wallpaper) && WebKitVideoPlayer.handles(wallpaper.mediaURL) {
            return chromiumInstalled ? .available : .needsChromium
        }
        if wallpaper.project != .invalid, SceneEditorModes.isVideo(wallpaper) {
            return .unavailable(String(localized: "The screen saver plays MP4 and MOV videos in H.264 or HEVC, and WebM videos through the Chromium engine",
                                       comment: "Details panel: why a video wallpaper in another codec has no screen saver"))
        }
        return .unavailable(String(localized: "Screen savers are made from scene, web and video wallpapers",
                                   comment: "Details panel: why an application wallpaper has no screen saver"))
    }

    nonisolated static func availability(of wallpaper: WEWallpaper) -> Availability {
        availability(of: wallpaper, chromiumInstalled: ChromiumEngineInstaller.hasActiveInstall)
    }

    /// Whether a menu offers Set as Screen Saver for `wallpaper`: it can be set, or it needs the
    /// Chromium engine first (choosing it then offers the install, `chromiumOffer`).
    nonisolated static func canSet(_ wallpaper: WEWallpaper) -> Bool {
        if case .unavailable = availability(of: wallpaper) { return false }
        return true
    }

    /// The menus' and the Details panel's Set as Screen Saver: `wallpaper` at once, with its
    /// default settings (every layer as authored, clocks on, its own property defaults), so any
    /// choices the Screen Saver tab saved for it are cleared; customising it stays in Scene Edit /
    /// Export's Screen Saver tab. A web wallpaper or WebM video without the Chromium engine isn't
    /// set: the install is offered (`chromiumOffer`). `completion` gets whether it was set.
    func setAsScreenSaver(_ wallpaper: WEWallpaper, completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        switch Self.availability(of: wallpaper) {
        case .available:
            break
        case .needsChromium:
            OWELog.info(.app, "Screen saver: \(wallpaper.wallpaperDirectory.lastPathComponent) needs the Chromium engine; offering it")
            chromiumOffer = wallpaper
            completion(false)
            return
        case .unavailable:
            OWELog.info(.app, "Screen saver: the screen saver can't show \(wallpaper.wallpaperDirectory.lastPathComponent)")
            completion(false)
            return
        }
        set(wallpaper, values: [:], completion: completion)
    }
}
