import Foundation

/// A wallpaper's saved presets ("Your Presets"), one JSON file per wallpaper under
/// `<AppStorageLocation.supportDirectory>/presets`, named by the wallpaper's settings identity
/// (`WallpaperSettingsIdentity`) so moving the library keeps them, as it keeps the properties.
///
/// They stay on this Mac and move between Macs as exported files: a Steam Web API key can only
/// read the Workshop, publishing an item takes `ISteamUGC` in a running Steam client, and Steam
/// Cloud (`ICloudService`) writes only to an app's own quota with a user's OAuth token.
struct WallpaperPresetStore {
    /// The file's layout, versioned so a later change can migrate it.
    private struct File: Codable {
        var version: Int = 1
        var presets: [WallpaperPreset]
    }

    let identity: WallpaperSettingsIdentity
    let fileURL: URL

    init(identity: WallpaperSettingsIdentity, directory: URL = Self.defaultDirectory) {
        self.identity = identity
        fileURL = directory.appending(path: identity.rawValue + ".json")
    }

    static var defaultDirectory: URL {
        AppStorageLocation.current.supportDirectory.appending(path: "presets", directoryHint: .isDirectory)
    }

    // MARK: Reading

    /// The saved presets, oldest first; none when the wallpaper has no file yet.
    func presets() throws -> [WallpaperPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        return try decoder.decode(File.self, from: data).presets
    }

    // MARK: Changing

    /// Saves `values` as the preset `name`: a new preset, or the one already called that
    /// (compared without case) with its values replaced, as saving over a file does.
    @discardableResult
    func save(name: String, values: [String: String]) throws -> WallpaperPreset {
        let name = try Self.validated(name)
        var presets = try presets()
        if let index = presets.firstIndex(where: { Self.sameName($0.name, name) }) {
            presets[index].values = values
            try write(presets)
            return presets[index]
        }
        let preset = WallpaperPreset(name: name, values: values)
        presets.append(preset)
        try write(presets)
        return preset
    }

    func rename(_ id: UUID, to newName: String) throws {
        let name = try Self.validated(newName)
        var presets = try presets()
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw WallpaperPresetError.notFound }
        if presets.contains(where: { $0.id != id && Self.sameName($0.name, name) }) {
            throw WallpaperPresetError.duplicateName(name)
        }
        presets[index].name = name
        try write(presets)
    }

    func delete(_ id: UUID) throws {
        var presets = try presets()
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw WallpaperPresetError.notFound }
        presets.remove(at: index)
        try write(presets)
    }

    // MARK: Files

    /// The preset `id` as an exported file's contents.
    func exportData(_ id: UUID) throws -> Data {
        guard let preset = try presets().first(where: { $0.id == id }) else { throw WallpaperPresetError.notFound }
        return try WallpaperPresetTransfer(wallpaper: identity.rawValue, preset: preset).encoded()
    }

    /// Adds the preset in an exported file's `data` as a new preset, renamed "Name 2", "Name 3"…
    /// when the name is taken. A preset of another wallpaper is refused.
    @discardableResult
    func importData(_ data: Data) throws -> WallpaperPreset {
        let transfer = try WallpaperPresetTransfer.decode(data)
        guard transfer.wallpaper == identity.rawValue else { throw WallpaperPresetError.otherWallpaper }
        return try add(name: transfer.preset.name, values: transfer.preset.values, created: transfer.preset.created)
    }

    /// Adds `values` as a new preset `name`, renamed "Name 2", "Name 3"… when the name is taken.
    @discardableResult
    func add(name: String, values: [String: String], created: Date = Date()) throws -> WallpaperPreset {
        var presets = try presets()
        let base = try Self.validated(name)
        var name = base
        var suffix = 2
        while presets.contains(where: { Self.sameName($0.name, name) }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let preset = WallpaperPreset(name: name, created: created, values: values)
        presets.append(preset)
        try write(presets)
        return preset
    }

    // MARK: Helpers

    private static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WallpaperPresetError.emptyName }
        return trimmed
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    /// Writes `presets`, removing the file once the last one is deleted.
    private func write(_ presets: [WallpaperPreset]) throws {
        let fileManager = FileManager.default
        if presets.isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
            return
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(File(presets: presets)).write(to: fileURL, options: .atomic)
    }
}
