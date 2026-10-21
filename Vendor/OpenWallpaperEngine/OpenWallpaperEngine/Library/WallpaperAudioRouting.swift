import Foundation

/// Where wallpapers' sound comes from (docs/architecture.md "Wallpaper instances").
///
/// Each running wallpaper plays its sound once, however many displays show it: a shared instance
/// (scene, Metal video, AVKit video) has one audio engine or player, and a wallpaper whose displays
/// run it as several instances (different user properties) plays from the one on its audible
/// display. A web wallpaper keeps a page
/// per display, and only the page on the wallpaper's audible display plays sound: the main
/// display when it shows the wallpaper, else the display with the lowest id. Different
/// wallpapers on different displays each play theirs. The app's "Audio Output" setting silences
/// them all; volume and mute (the status menu) apply to every one.
enum WallpaperAudioRouting {
    /// The display whose view of `key`'s wallpaper plays its sound, among the enabled displays
    /// `assignments` shows it on; nil when none does.
    static func audibleScreen(of key: WallpaperInstanceKey, assignments: [String: WallpaperInstanceKey],
                              enabledScreens: Set<String>, mainScreen: String?) -> String? {
        let showing = assignments.compactMap { screen, assigned in
            enabledScreens.contains(screen) && assigned == key ? screen : nil
        }
        if let mainScreen, showing.contains(mainScreen) { return mainScreen }
        return showing.min()
    }

    /// The instance that plays `wallpaper`'s sound when its displays run it as several instances
    /// (their properties differ, `WallpaperPropertyGroups`): the one on its audible display, so the
    /// wallpaper still plays once. `instanceKeys` holds each display's instance; nil when no
    /// enabled display shows the wallpaper.
    static func audibleInstance(of wallpaper: WallpaperInstanceKey, instanceKeys: [String: WallpaperInstanceKey],
                                enabledScreens: Set<String>, mainScreen: String?) -> WallpaperInstanceKey? {
        let screen = audibleScreen(of: wallpaper.wallpaper, assignments: instanceKeys.mapValues(\.wallpaper),
                                   enabledScreens: enabledScreens, mainScreen: mainScreen)
        return screen.flatMap { instanceKeys[$0] }
    }
}
