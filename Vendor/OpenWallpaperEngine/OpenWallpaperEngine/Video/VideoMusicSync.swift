import Cocoa
import SwiftUI
import AVKit

enum VideoMusicSyncSettings {
    static func key(_ wallpaper: WEWallpaper, _ name: String) -> String {
        "VideoMusicSync.\(wallpaper.wallpaperDirectory.path).\(name)"
    }

    static func bool(_ wallpaper: WEWallpaper, _ name: String) -> Bool {
        UserDefaults.app.bool(forKey: key(wallpaper, name))
    }

    /// The music-sync switches; any of them on makes the wallpaper follow the system audio.
    static let switches = ["zoomEnabled", "tiltEnabled", "saturationEnabled", "paceEnabled"]

    /// Whether any music sync is on for `wallpaper`, so it needs system audio capture.
    static func isAnyEnabled(_ wallpaper: WEWallpaper) -> Bool {
        switches.contains { bool(wallpaper, $0) }
    }

    static func double(_ wallpaper: WEWallpaper, _ name: String, default defaultValue: Double = 0) -> Double {
        let key = key(wallpaper, name)
        return UserDefaults.app.object(forKey: key) == nil ? defaultValue : UserDefaults.app.double(forKey: key)
    }
}

/// UserDefaults is invisible to SwiftUI and to the Metal renderer, which bakes the zoom/tilt/
/// saturation amounts into a layer at build time. Routing writes through here gives both a change
/// signal, so the controls redraw and the wallpaper picks the new values up immediately.
final class VideoMusicSyncStore: ObservableObject {
    static let shared = VideoMusicSyncStore()

    @Published private(set) var revision = 0

    private init() {}

    func set(_ value: Bool, _ wallpaper: WEWallpaper, _ name: String) {
        UserDefaults.app.set(value, forKey: VideoMusicSyncSettings.key(wallpaper, name))
        didChange(wallpaper)
    }

    func set(_ value: Double, _ wallpaper: WEWallpaper, _ name: String) {
        UserDefaults.app.set(value, forKey: VideoMusicSyncSettings.key(wallpaper, name))
        didChange(wallpaper)
    }

    private func didChange(_ wallpaper: WEWallpaper) {
        revision &+= 1
        NotificationCenter.default.post(name: .videoMusicSyncSettingsDidChange, object: nil,
                                        userInfo: ["path": wallpaper.wallpaperDirectory.path])
    }
}
