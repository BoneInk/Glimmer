import Foundation

/// How each display's playback (`DisplayPlayback`, from the playback rules) reaches the wallpaper
/// instances, which run once however many displays show them (docs/architecture.md "Wallpaper
/// instances").
///
/// - An instance renders while any display showing it plays; a paused display keeps its last
///   frame. It stops rendering only when every display showing it is paused or stopped.
/// - A wallpaper's sound plays once, so it goes quiet only when every display showing the
///   wallpaper (with whatever properties) is muted, paused or stopped.
///
/// A display without a state (not evaluated yet, or the Workshop preview) plays.
enum DisplayPlaybackRouting {
    /// What the displays showing the instance `key` agree on (`DisplayPlayback.shared`).
    static func instance(_ key: WallpaperInstanceKey, instanceKeys: [String: WallpaperInstanceKey],
                         enabledScreens: Set<String>, states: [String: DisplayPlayback]) -> DisplayPlayback {
        shared(screens(instanceKeys, enabledScreens) { $0 == key }, states)
    }

    /// What the displays showing `key`'s wallpaper agree on, whatever their properties: its sound's
    /// playback, and the frames of a player shared by every display showing the wallpaper.
    static func wallpaper(_ key: WallpaperInstanceKey, instanceKeys: [String: WallpaperInstanceKey],
                          enabledScreens: Set<String>, states: [String: DisplayPlayback]) -> DisplayPlayback {
        let wallpaper = key.wallpaper
        return shared(screens(instanceKeys, enabledScreens) { $0.wallpaper == wallpaper }, states)
    }

    /// The displays the wallpaper's sound may come from: those that play it unmuted when there are
    /// any, so a display that plays keeps the sound when the one it used to come from pauses.
    static func audibleCandidates(of key: WallpaperInstanceKey, instanceKeys: [String: WallpaperInstanceKey],
                                  enabledScreens: Set<String>, states: [String: DisplayPlayback]) -> Set<String> {
        let wallpaper = key.wallpaper
        let showing = screens(instanceKeys, enabledScreens) { $0.wallpaper == wallpaper }
        let playing = showing.filter { (states[$0] ?? .run).playsSound }
        return playing.isEmpty ? enabledScreens : playing
    }

    private static func screens(_ instanceKeys: [String: WallpaperInstanceKey], _ enabledScreens: Set<String>,
                                matching: (WallpaperInstanceKey) -> Bool) -> Set<String> {
        Set(instanceKeys.compactMap { screen, key in enabledScreens.contains(screen) && matching(key) ? screen : nil })
    }

    private static func shared(_ screens: Set<String>, _ states: [String: DisplayPlayback]) -> DisplayPlayback {
        DisplayPlayback.shared(screens.map { states[$0] ?? .run })
    }
}
