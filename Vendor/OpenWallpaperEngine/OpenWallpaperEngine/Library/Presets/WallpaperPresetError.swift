import Foundation

/// Why a preset could not be saved, renamed or imported.
enum WallpaperPresetError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case notFound
    case notAPresetFile
    case otherWallpaper
    case notAConfigFile
    /// Pasted text or a file with none of this wallpaper's properties in it.
    case noMatchingProperties

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return String(localized: "A preset needs a name.", comment: "Error when saving or renaming a wallpaper preset without a name")
        case .duplicateName(let name):
            return String(localized: "A preset named “\(name)” already exists.",
                          comment: "Error when renaming a wallpaper preset to a name another preset has; the name")
        case .notFound:
            return String(localized: "The preset no longer exists.", comment: "Error when acting on a wallpaper preset that was deleted meanwhile")
        case .notAPresetFile:
            return String(localized: "The file is not a wallpaper preset.", comment: "Error when importing a file that is not an exported wallpaper preset")
        case .otherWallpaper:
            return String(localized: "The preset was made for a different wallpaper.",
                          comment: "Error when importing a wallpaper preset exported from another wallpaper")
        case .notAConfigFile:
            return String(localized: "The file is not a Wallpaper Engine config.json.",
                          comment: "Error when importing presets from a file that is not Wallpaper Engine's config.json")
        case .noMatchingProperties:
            return String(localized: "None of this wallpaper's properties are in it.",
                          comment: "Error when pasted or imported preset JSON sets no property of the shown wallpaper")
        }
    }
}
