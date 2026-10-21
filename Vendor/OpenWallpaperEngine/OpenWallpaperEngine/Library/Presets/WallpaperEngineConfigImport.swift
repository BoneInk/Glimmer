import Foundation

/// "Import from Wallpaper Engine config.json…": the presets and property values a Wallpaper
/// Engine install saved, added as presets of the matching installed wallpapers.
///
/// WE's `config.json` keeps one object per Windows user (keys starting with "?" are not users).
/// In each:
/// - `general.wpresets` maps the file a wallpaper plays (`…/431960/<id>/scene.pkg`) to
///   `{"presets": [{"name", "properties": {key: value}}]}`, the Share JSON values of each preset;
/// - `wproperties` maps that file to the values set per display (`{"<monitor>": {key: value}}`),
///   or, in older files, straight to `{key: value}`.
///
/// The paths are absolute Windows paths with the user's name in them, so a wallpaper is matched
/// only by its Workshop id, the folder after `431960`. The values are checked against the
/// installed wallpaper's properties (`WallpaperEngineShareJSON.values`). Unknown fields are
/// ignored; a file that isn't a config.json is an error.
struct WallpaperEngineConfigImport {
    /// One wallpaper's presets as found in the file.
    struct Entry: Equatable {
        var workshopID: String
        /// Name and raw values, in file order; saved property values come last, unnamed.
        var presets: [(name: String?, values: [String: Any])]

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.workshopID == rhs.workshopID && lhs.presets.count == rhs.presets.count
                && zip(lhs.presets, rhs.presets).allSatisfy { $0.name == $1.name && NSDictionary(dictionary: $0.values).isEqual(to: $1.values) }
        }
    }

    struct Summary: Equatable {
        var presets = 0
        var wallpapers = 0
        /// Workshop items with saved presets or values that aren't installed.
        var notInstalled = 0
    }

    /// The Steam app id of Wallpaper Engine, the folder Workshop items live under.
    static let workshopAppID = "431960"

    /// The entries in a config.json's `data`, one per Workshop item, in id order. Throws
    /// `WallpaperPresetError.notAConfigFile` when `data` isn't a JSON object with a user in it.
    static func entries(in data: Data) throws -> [Entry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw WallpaperPresetError.notAConfigFile
        }
        let users = root.filter { !$0.key.hasPrefix("?") }.compactMap { $0.value as? [String: Any] }
            .filter { $0["general"] is [String: Any] || $0["wproperties"] is [String: Any] }
        guard !users.isEmpty else { throw WallpaperPresetError.notAConfigFile }
        var byID: [String: Entry] = [:]
        var order: [String] = []
        func add(_ path: String, name: String?, values: [String: Any]) {
            guard let id = workshopID(inPath: path), !values.isEmpty else { return }
            if byID[id] == nil { byID[id] = Entry(workshopID: id, presets: []); order.append(id) }
            byID[id]?.presets.append((name, values))
        }
        for user in users {
            let general = user["general"] as? [String: Any]
            for key in ["wpresets", "wallpaperpresets"] {
                for (path, entry) in general?[key] as? [String: Any] ?? [:] {
                    for preset in (entry as? [String: Any])?["presets"] as? [Any] ?? [] {
                        guard let preset = preset as? [String: Any],
                              let values = preset["properties"] as? [String: Any] else { continue }
                        add(path, name: preset["name"] as? String, values: values)
                    }
                }
            }
        }
        for user in users {
            for (path, entry) in user["wproperties"] as? [String: Any] ?? [:] {
                guard let entry = entry as? [String: Any] else { continue }
                if !entry.isEmpty, entry.values.allSatisfy({ $0 is [String: Any] }) {
                    // One set per display or display group; the same values once.
                    var seen: [NSDictionary] = []
                    for key in entry.keys.sorted() {
                        guard let values = entry[key] as? [String: Any] else { continue }
                        let dictionary = NSDictionary(dictionary: values)
                        guard !seen.contains(dictionary) else { continue }
                        seen.append(dictionary)
                        add(path, name: nil, values: values)
                    }
                } else {
                    add(path, name: nil, values: entry)
                }
            }
        }
        return order.sorted().compactMap { byID[$0] }
    }

    /// The Workshop id in a WE path: the numeric folder after `431960`, whichever slashes.
    static func workshopID(inPath path: String) -> String? {
        let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let index = parts.lastIndex(of: workshopAppID), index + 1 < parts.count else { return nil }
        let id = parts[index + 1]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    /// Adds the entries' presets to the installed wallpapers they belong to. Presets whose values
    /// don't fit the wallpaper's properties are skipped; names already taken are numbered.
    /// `savedValuesName` names the presets made from saved property values.
    static func importEntries(_ entries: [Entry], installed: [WEWallpaper], savedValuesName: String,
                              store: (WallpaperSettingsIdentity) -> WallpaperPresetStore = { WallpaperPresetStore(identity: $0) },
                              defaults: UserDefaults = .app) throws -> Summary {
        var byID: [String: WEWallpaper] = [:]
        for wallpaper in installed {
            let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
            if identity.rawValue.hasPrefix("workshop-") { byID[String(identity.rawValue.dropFirst("workshop-".count))] = wallpaper }
        }
        var summary = Summary()
        for entry in entries {
            guard let wallpaper = byID[entry.workshopID] else {
                summary.notInstalled += 1
                continue
            }
            let identity = WallpaperSettingsIdentity.resolve(wallpaper, defaults: defaults)
            let definitions = WallpaperEngineShareJSON.definitions(in: wallpaper.wallpaperDirectory)
            let presets = store(identity)
            var added = 0
            for preset in entry.presets {
                let values = WallpaperEngineShareJSON.values(from: preset.values, definitions: definitions)
                guard !values.isEmpty else { continue }
                let name = preset.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                try presets.add(name: (name?.isEmpty ?? true) ? savedValuesName : name!, values: values)
                added += 1
            }
            if added > 0 {
                summary.presets += added
                summary.wallpapers += 1
            }
        }
        return summary
    }
}
