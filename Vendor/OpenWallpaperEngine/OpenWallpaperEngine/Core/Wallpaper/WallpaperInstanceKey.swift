import Foundation

/// What makes two displays show the same running wallpaper: the same wallpaper folder, file and
/// type, and the same user properties. Displays whose keys are equal share one instance
/// (`WallpaperInstanceRegistry`); a display switched to another wallpaper, or given other
/// properties, gets another key and splits off into its own.
///
/// `properties` is the store the instance runs with (`WallpaperPropertyScope`): the shared one
/// while properties are synced across displays, else a display's own. Displays whose own
/// properties are equal share the instance of the first of them (`WallpaperPropertyGroups`).
struct WallpaperInstanceKey: Hashable, CustomStringConvertible {
    let directory: String
    let file: String
    let type: String
    var properties: WallpaperPropertyScope = .shared

    init(_ wallpaper: WEWallpaper, properties: WallpaperPropertyScope = .shared) {
        directory = wallpaper.wallpaperDirectory.standardizedFileURL.path
        file = wallpaper.project.file
        type = wallpaper.project.type.lowercased()
        self.properties = properties
    }

    /// The wallpaper alone, whatever its properties: what plays its sound once.
    var wallpaper: WallpaperInstanceKey {
        var key = self
        key.properties = .shared
        return key
    }

    var description: String {
        properties == .shared ? "\(type) \(directory)/\(file)" : "\(type) \(directory)/\(file) (\(properties))"
    }
}
