import Foundation

/// A preset exported to a file (Export and Import in "Your Presets"): the preset and the
/// settings identity (`WallpaperSettingsIdentity`) of the wallpaper it belongs to, so it is only
/// imported into that wallpaper.
struct WallpaperPresetTransfer: Codable, Equatable {
    static let formatName = "open-wallpaper-engine.preset"
    static let currentVersion = 1

    var format: String = Self.formatName
    var version: Int = Self.currentVersion
    /// `WallpaperSettingsIdentity.rawValue` of the wallpaper the preset was saved from.
    var wallpaper: String
    var preset: WallpaperPreset

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// The transfer in `data`; `WallpaperPresetError.notAPresetFile` for any other JSON or a
    /// newer format version.
    static func decode(_ data: Data) throws -> WallpaperPresetTransfer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transfer: WallpaperPresetTransfer
        do {
            transfer = try decoder.decode(WallpaperPresetTransfer.self, from: data)
        } catch {
            throw WallpaperPresetError.notAPresetFile
        }
        guard transfer.format == formatName, transfer.version <= currentVersion else {
            throw WallpaperPresetError.notAPresetFile
        }
        return transfer
    }

    /// A file name for the preset, without characters Finder won't take.
    var suggestedFileName: String {
        let cleaned = preset.name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return (cleaned.isEmpty ? "preset" : cleaned) + ".json"
    }
}
