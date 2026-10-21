import Foundation

/// The app's Animation Speed: WE's per-wallpaper playback `rate` (÷ 100), which `SceneClock`
/// multiplies the frame by. It is a user property of the wallpaper instance, so it lives in the
/// instance's own property store (`WallpaperPropertyScope.runtimeKey`): with properties per
/// display, two displays showing one wallpaper run it at their own speeds, as WE's per-monitor
/// wallpapers each have their own `rate`.
enum ScenePlaybackSpeed {
    /// The property the sidebar's Animation Speed slider writes.
    static let propertyKey = "_owe_speed"

    /// The speed stored for the instance whose property store is `store`; 1 when it has none or
    /// it isn't a number.
    static func speed(ofStore store: String, services: WallpaperServices = .shared) -> Double {
        guard let text = services.userPropertyString(propertyKey, wallpaper: store),
              let value = Double(text.trimmingCharacters(in: .whitespaces)), value.isFinite else { return 1 }
        return value
    }
}
