import Foundation
import Combine

final class DownloadedWallpaperIndex: ObservableObject {
    static let shared = DownloadedWallpaperIndex()

    @Published private(set) var ids: Set<String>
    /// Steam's tags of installed Workshop wallpapers, by Workshop id (`InstalledWorkshopTagSync`).
    @Published private(set) var workshopTags: [String: InstalledWorkshopTags]
    private let storageKey = "DownloadedWorkshopWallpaperIds"
    private let dateStorageKey = "DownloadedWorkshopWallpaperDates"
    private let tagsStorageKey = "DownloadedWorkshopWallpaperTags"
    private var downloadDates: [String: Date]
    private let defaults: UserDefaults
    private let libraryDirectory: () -> URL

    init(defaults: UserDefaults = .app,
         libraryDirectory: @escaping () -> URL = { FileManager.default.wallpapersDirectory }) {
        self.defaults = defaults
        self.libraryDirectory = libraryDirectory
        ids = Set(defaults.stringArray(forKey: storageKey) ?? [])
        downloadDates = Self.decodeDates(defaults.dictionary(forKey: dateStorageKey))
        workshopTags = Self.decodeTags(defaults.data(forKey: tagsStorageKey))
        if ids.isEmpty || downloadDates.isEmpty {
            rebuildFromLibrary()
        }
    }

    func contains(_ workshopId: String) -> Bool {
        ids.contains(workshopId)
    }

    func insert(_ workshopId: String) {
        ids.insert(workshopId)
        if downloadDates[workshopId] == nil {
            downloadDates[workshopId] = .now
        }
        save()
    }

    func dateAdded(for directory: URL) -> Date {
        let workshopId = directory.lastPathComponent
        if let date = downloadDates[workshopId] {
            return date
        }
        return (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    func workshopTags(for workshopId: String) -> InstalledWorkshopTags? {
        workshopTags[workshopId]
    }

    func setWorkshopTags(_ entries: [String: InstalledWorkshopTags]) {
        guard !entries.isEmpty else { return }
        workshopTags.merge(entries) { _, new in new }
        saveTags()
    }

    func remove(directory: URL) {
        let workshopId = directory.lastPathComponent
        if workshopTags.removeValue(forKey: workshopId) != nil {
            saveTags()
        }
        guard ids.remove(workshopId) != nil else { return }
        downloadDates.removeValue(forKey: workshopId)
        save()
    }

    func reloadFromLibrary() {
        ids.removeAll()
        downloadDates.removeAll()
        rebuildFromLibrary()
    }

    private func rebuildFromLibrary() {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: libraryDirectory(),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let downloadedDirectories = directories.compactMap { directory -> URL? in
            let workshopId = directory.lastPathComponent
            guard workshopId.allSatisfy(\.isNumber),
                  WEProject.exists(in: directory) else {
                return nil
            }
            return directory
        }
        ids = Set(downloadedDirectories.map(\.lastPathComponent))
        for directory in downloadedDirectories {
            let workshopId = directory.lastPathComponent
            if downloadDates[workshopId] == nil {
                downloadDates[workshopId] = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            }
        }
        save()
    }

    private func save() {
        defaults.set(ids.sorted(), forKey: storageKey)
        defaults.set(
            downloadDates.mapValues(\.timeIntervalSince1970),
            forKey: dateStorageKey
        )
    }

    private func saveTags() {
        do {
            defaults.set(try JSONEncoder().encode(workshopTags), forKey: tagsStorageKey)
        } catch {
            OWELog.error(.library, "Can't save the installed wallpapers' Workshop tags: \(error)")
        }
    }

    /// The stored tags; a list that doesn't decode is dropped and read again from Steam.
    private static func decodeTags(_ data: Data?) -> [String: InstalledWorkshopTags] {
        guard let data else { return [:] }
        do {
            return try JSONDecoder().decode([String: InstalledWorkshopTags].self, from: data)
        } catch {
            OWELog.error(.library, "Can't read the installed wallpapers' Workshop tags: \(error)")
            return [:]
        }
    }

    private static func decodeDates(_ storedDates: [String: Any]?) -> [String: Date] {
        (storedDates ?? [:]).reduce(into: [:]) { dates, entry in
            guard let timestamp = entry.value as? Double else { return }
            dates[entry.key] = Date(timeIntervalSince1970: timestamp)
        }
    }
}

/// Tracks favorited wallpapers, keyed by an arbitrary caller-chosen ID (local wallpaper directory
/// path, or "workshop-<id>" for not-yet-downloaded Workshop items).
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    @Published private(set) var ids: Set<String>
    private let storageKey = "FavoriteWallpaperIds"
    private let defaults: UserDefaults

    /// The app's store reads `UserDefaults.app`; tests pass their own suite.
    init(defaults: UserDefaults = .app) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    func toggle(_ id: String) {
        if ids.contains(id) {
            ids.remove(id)
        } else {
            ids.insert(id)
        }
        save()
    }

    /// Adds `keys` to the favourites, keeping every one already there; returns how many were new.
    /// Merging the same keys again adds nothing.
    @discardableResult
    func merge(_ keys: some Sequence<String>) -> Int {
        let new = Set(keys).subtracting(ids)
        guard !new.isEmpty else { return 0 }
        ids.formUnion(new)
        save()
        return new.count
    }

    private func save() {
        defaults.set(ids.sorted(), forKey: storageKey)
    }

    /// A Workshop wallpaper keeps one identity whether or not it is installed, so favouriting it in
    /// the Workshop tab and in the local library refer to the same entry.
    static func key(for wallpaper: WEWallpaper) -> String {
        if let id = wallpaper.project.workshopid?.rawValue, !id.isEmpty, id.allSatisfy(\.isNumber) {
            return "workshop-\(id)"
        }
        let folder = wallpaper.wallpaperDirectory.lastPathComponent
        if !folder.isEmpty, folder.allSatisfy(\.isNumber) { return "workshop-\(folder)" }
        return wallpaper.wallpaperDirectory.path
    }

    func contains(_ wallpaper: WEWallpaper) -> Bool {
        ids.contains(Self.key(for: wallpaper)) || ids.contains(wallpaper.wallpaperDirectory.path)
    }

    func toggle(_ wallpaper: WEWallpaper) {
        if contains(wallpaper) {
            // Older builds keyed local copies by path; drop both so it cannot stay half-favourited.
            ids.remove(Self.key(for: wallpaper))
            ids.remove(wallpaper.wallpaperDirectory.path)
        } else {
            ids.insert(Self.key(for: wallpaper))
        }
        save()
    }
}

/// Whether a wallpaper's project.json declares any user-editable properties beyond the default color scheme.
func projectHasCustomizableProperties(at wallpaperDirectory: URL) -> Bool {
    // Optional: asked for every tile; a project.json that can't be read already shows the
    // wallpaper as invalid, so it has no properties to customise here.
    guard let root = try? WEProject.json(in: wallpaperDirectory),
          let properties = (root["general"] as? [String: Any])?["properties"] as? [String: Any] else { return false }
    return properties.keys.contains { $0 != "schemecolor" }
}

extension FileManager {
    /// The configured directory for storing wallpaper packages.
    /// Created when missing, unless its volume isn't connected; code that writes into it checks
    /// `WallpaperStorage.availableDirectory()` for the reason.
    var wallpapersDirectory: URL {
        let dir = WallpaperStorage.directory
        guard !fileExists(atPath: dir.path) else { return dir }
        do {
            _ = try WallpaperStorage.availableDirectory(dir, fileManager: self)
        } catch {
            OWELog.error(.library, "\(error.localizedDescription)")
        }
        return dir
    }
}
