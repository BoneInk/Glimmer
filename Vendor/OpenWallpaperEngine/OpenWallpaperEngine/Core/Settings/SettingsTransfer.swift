import Foundation

/// Settings › Export and Import: the app's settings as a JSON file, to move them to another Mac
/// or keep a copy.
///
/// The file holds the global settings, the on/off preferences stored beside them, Sparkle's
/// update choices and the Installed tab's folders. It never holds secrets: the Steam Web API key and the Steam account stay in
/// the Keychain and are never read here. Paths (the Wallpaper Storage folder, a chosen assets
/// folder) are left out too, since they belong to one Mac.
struct SettingsTransfer: Codable, Equatable {
    /// Identifies the file, so importing some other JSON fails clearly.
    static let formatName = "open-wallpaper-engine-settings"
    static let currentVersion = 1

    /// The on/off preferences kept in `UserDefaults.app` outside `GlobalSettings` that travel
    /// with the settings. Nothing secret is stored under these keys. A file from an older version
    /// may still hold the retired Animated Thumbnails key; `decode` drops it like any unknown key.
    static let preferenceKeys: [String] = [
        "ReclaimOriginalPackages",
        "HidesReleaseNotesAfterUpdate",
        "ReceiveBetaUpdates",
    ]

    /// Sparkle's choices, which Sparkle keeps itself (`AppUpdater`).
    struct Updates: Codable, Equatable {
        var automaticallyChecksForUpdates: Bool
        var updatesAutomatically: Bool
    }

    var format: String = Self.formatName
    var version: Int = Self.currentVersion
    /// The version of the app that wrote the file, for people reading it.
    var appVersion: String
    var settings: GlobalSettings
    var preferences: [String: Bool]
    var updates: Updates?
    /// The Installed tab's folders (`InstalledFolderStore`); nil in a file from before them, or
    /// when there are none. Importing merges them into the folders there (`InstalledFolderTree.merge`).
    var folders: InstalledFolderTree?

    enum TransferError: LocalizedError {
        case notSettingsFile
        case newerVersion(Int)

        var errorDescription: String? {
            switch self {
            case .notSettingsFile:
                return String(localized: "This file isn't an Open Wallpaper Engine settings file.")
            case .newerVersion:
                return String(localized: "These settings were exported by a newer version of Open Wallpaper Engine. Update the app to import them.")
            }
        }
    }

    /// The settings as they are now.
    static func export(settings: GlobalSettings, defaults: UserDefaults, updates: Updates?, appVersion: String) -> SettingsTransfer {
        var preferences: [String: Bool] = [:]
        for key in preferenceKeys where defaults.object(forKey: key) != nil {
            preferences[key] = defaults.bool(forKey: key)
        }
        let folders = InstalledFolderStore.load(from: defaults)
        return SettingsTransfer(appVersion: appVersion, settings: settings, preferences: preferences, updates: updates,
                                folders: folders.folders.isEmpty ? nil : folders)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads an exported file. Unknown preferences are dropped; settings missing from an older
    /// file keep their defaults (`GlobalSettings.init(from:)`); an earlier Render Resolution is
    /// carried over for `migration`'s display.
    static func decode(_ data: Data, migration: GlobalSettingsMigration? = nil) throws -> SettingsTransfer {
        let transfer: SettingsTransfer
        do {
            transfer = try (migration?.decoder() ?? JSONDecoder()).decode(SettingsTransfer.self, from: data)
        } catch {
            throw TransferError.notSettingsFile
        }
        guard transfer.format == formatName else { throw TransferError.notSettingsFile }
        guard transfer.version <= currentVersion else { throw TransferError.newerVersion(transfer.version) }
        var known = transfer
        known.preferences = transfer.preferences.filter { preferenceKeys.contains($0.key) }
        return known
    }

    /// Writes the preferences into `defaults`; the caller applies `settings` and `updates`.
    func applyPreferences(to defaults: UserDefaults) {
        for (key, value) in preferences where Self.preferenceKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
    }
}
