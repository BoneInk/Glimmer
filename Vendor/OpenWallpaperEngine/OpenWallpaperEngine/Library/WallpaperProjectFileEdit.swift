import Foundation

/// Edits a few top-level keys of a wallpaper's project.json in place. `WEProject` doesn't model
/// everything the file holds (`general.properties`, editor and Workshop keys…), so re-encoding it
/// would drop them: the file is read as a JSON object, only the edited keys change, and every other
/// key is written back as read.
enum WallpaperProjectFileEdit {
    /// Sets each key to its value, or removes it when the value is nil.
    static func set(_ values: [String: Any?], inProjectAt directory: URL, defaults: UserDefaults = .app) throws {
        // A local wallpaper's settings identity is registered before its bytes change, so the edit
        // keeps its settings even when it was never resolved before.
        _ = WallpaperSettingsIdentity.resolve(directory: directory, defaults: defaults)
        let url = WEProject.url(in: directory)
        let data = try Data(contentsOf: url)
        guard var project = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        for (key, value) in values {
            project[key] = value
        }
        try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            .write(to: url, options: .atomic)
    }

    /// `set`, logging a failure with the wallpaper and the keys. Returns whether the file was written.
    @discardableResult
    static func setLogging(_ values: [String: Any?], inProjectAt directory: URL) -> Bool {
        do {
            try set(values, inProjectAt: directory)
            return true
        } catch {
            OWELog.error(.library, "Can't set \(values.keys.sorted().joined(separator: ", ")) in \(directory.lastPathComponent)/project.json: \(error)")
            return false
        }
    }
}
