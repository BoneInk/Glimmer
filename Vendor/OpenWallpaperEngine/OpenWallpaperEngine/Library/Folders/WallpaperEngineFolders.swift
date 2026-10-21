import Foundation

/// Wallpaper Engine's Installed folders, read from its `config.json` for importing.
///
/// WE keeps them in `config.json` beside `wallpaper64.exe`, per account, under
/// `<account>.general.browser.folders`: a list of
/// `{"type": "folder", "title": …, "items": {<key>: 1, …}, "subfolders": [ … ]}`, with an
/// optional `folderColor` (a `browseFolderColor…` class) and `folderIcon` (a Font Awesome class;
/// `folderIconOpen` is the open variant). An item's key is its Workshop id, or for a local
/// wallpaper its file's path on the PC. Each wallpaper is in one folder at most; folders nest.
enum WallpaperEngineFolders {
    /// `config.json` of the Wallpaper Engine install the chosen assets folder is (or is the
    /// `assets` folder of); nil when there is none, as for the cache SteamCMD fills.
    static func configURL(chosenFolder: String?, fileManager: FileManager = .default) -> URL? {
        guard let chosenFolder, !chosenFolder.isEmpty else { return nil }
        var root = URL(fileURLWithPath: chosenFolder, isDirectory: true).standardizedFileURL
        if root.lastPathComponent.caseInsensitiveCompare("assets") == .orderedSame {
            root = root.deletingLastPathComponent()
        }
        let config = root.appending(path: "config.json")
        return fileManager.fileExists(atPath: config.path) ? config : nil
    }

    enum ReadError: LocalizedError {
        case notConfig

        var errorDescription: String? {
            String(localized: "Wallpaper Engine's config.json can't be read.",
                   comment: "Error when importing Wallpaper Engine's folders from its settings file")
        }
    }

    /// The folders of every account in `config.json`, in the accounts' name order, with WE's own
    /// item keys. A folder without a title is skipped with its contents, as WE skips it.
    static func folders(inConfig data: Data) throws -> [InstalledFolder] {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ReadError.notConfig }
            root = object
        } catch {
            throw ReadError.notConfig
        }
        var result: [InstalledFolder] = []
        for account in root.keys.sorted() {
            guard let general = (root[account] as? [String: Any])?["general"] as? [String: Any],
                  let list = (general["browser"] as? [String: Any])?["folders"] as? [Any] else { continue }
            result += list.compactMap(folder)
        }
        return result
    }

    private static func folder(_ value: Any) -> InstalledFolder? {
        guard let entry = value as? [String: Any],
              let title = (entry["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        if let type = entry["type"] as? String, type != "folder" { return nil }
        var items = Set<String>()
        if let map = entry["items"] as? [String: Any] {
            items = Set(map.compactMap { key, flag in isSet(flag) ? key : nil })
        } else if let list = entry["items"] as? [String] {
            items = Set(list)
        }
        return InstalledFolder(title: title,
                               color: (entry["folderColor"] as? String).flatMap(InstalledFolderColor.init(weClass:)),
                               icon: icon(entry),
                               items: items,
                               subfolders: (entry["subfolders"] as? [Any] ?? []).compactMap(folder))
    }

    /// The folder's icon: `folderIcon`, or when that isn't one of WE's the icon whose open variant
    /// is `folderIconOpen`; nil (WE's plain folder) when neither is, as when both are absent.
    private static func icon(_ entry: [String: Any]) -> InstalledFolderIcon? {
        (entry["folderIcon"] as? String).flatMap(InstalledFolderIcon.init(weClass:))
            ?? (entry["folderIconOpen"] as? String).flatMap(InstalledFolderIcon.init(weOpenClass:))
    }

    /// WE writes `1`; anything true-ish counts.
    private static func isSet(_ flag: Any) -> Bool {
        if let number = flag as? NSNumber { return number.boolValue }
        return !(flag is NSNull)
    }

    /// The key a WE item has here (`FavoritesStore.key(for:)`): `workshop-<id>` for a Workshop
    /// id; for a local wallpaper's path, the key of the installed wallpaper whose folder has the
    /// same name (`localKeys`, by folder name); nil for one that isn't here (or a web address).
    static func key(forItem item: String, localKeys: [String: String]) -> String? {
        let trimmed = item.trimmingCharacters(in: .whitespaces)
        if WorkshopCollection.isID(trimmed) { return "workshop-\(trimmed)" }
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }
        var components = trimmed.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        // The wallpaper's file (project.json, scene.json, a video): its folder names it.
        if let last = components.last, last.contains("."), components.count > 1 { components.removeLast() }
        guard let name = components.last else { return nil }
        if WorkshopCollection.isID(name) { return "workshop-\(name)" }
        return localKeys[name]
    }

    /// `folders` with each item's key as here, dropping the items that aren't.
    static func importable(_ folders: [InstalledFolder], localKeys: [String: String]) -> [InstalledFolder] {
        folders.map { folder in
            var mapped = folder
            mapped.items = Set(folder.items.compactMap { key(forItem: $0, localKeys: localKeys) })
            mapped.subfolders = importable(folder.subfolders, localKeys: localKeys)
            return mapped
        }
    }

    /// The installed wallpapers' keys by folder name, for `key(forItem:localKeys:)`; the first
    /// wallpaper of a name wins, as the library lists only the first.
    static func localKeys(of wallpapers: [WEWallpaper]) -> [String: String] {
        var keys: [String: String] = [:]
        for wallpaper in wallpapers {
            let name = wallpaper.wallpaperDirectory.lastPathComponent
            if keys[name] == nil { keys[name] = FavoritesStore.key(for: wallpaper) }
        }
        return keys
    }
}
