import Foundation

/// Imports the Wallpaper Engine Workshop items of an existing Steam install (Windows, a CrossOver
/// bottle, Boot Camp) from its `steamapps` folder: `workshop/appworkshop_431960.acf` lists the
/// subscribed and installed items, and each item's files are in `workshop/content/431960/<id>`.
/// Items are copied into the Wallpaper Storage folder, never moved, so Steam keeps its own copy.
enum SteamLibraryImport {
    static var appID: String { String(WorkshopAPIService.wallpaperEngineAppId) }

    /// One Workshop item found in the install.
    struct Item: Identifiable, Equatable {
        let id: String
        let folder: URL
        var title: String
        /// The project's type, lower-cased (`WallpaperEngineDefaultProjects.type(ofProjectAt:)`);
        /// empty for an asset item.
        var type: String
        var preview: URL?
        /// "Everyone", "Questionable" or "Mature", as WE stores it; nil when the project has none.
        var contentRating: String?
        /// In the manifest's details (subscribed), not just a folder on disk.
        var isSubscribed: Bool

        /// Application wallpapers never come in.
        var isImportable: Bool { type != "application" }
    }

    struct CopyResult: Equatable {
        var copied: [String] = []
        /// Already in the storage folder; left as they were.
        var existing: [String] = []
        /// Application items.
        var unsupported: [String] = []
        var failed: [String] = []
    }

    enum Failure: LocalizedError, Equatable {
        case notASteamLibrary(URL)

        var errorDescription: String? {
            switch self {
            case .notASteamLibrary(let url):
                return String(localized: "\(url.lastPathComponent) isn't a Steam library with Wallpaper Engine Workshop items. Choose the Steam folder or its steamapps folder.",
                              comment: "%@ is a folder name; steamapps is a folder name")
            }
        }
    }

    // MARK: Finding the library

    /// The `steamapps` folder of what the user chose: the Steam folder, `steamapps` itself, or a
    /// folder inside it (`workshop`, `workshop/content`, `workshop/content/431960`).
    static func steamapps(from chosen: URL, fileManager: FileManager = .default) -> URL? {
        var candidate = chosen.standardizedFileURL
        for _ in 0..<4 {
            if candidate.lastPathComponent.caseInsensitiveCompare("steamapps") == .orderedSame,
               isLibrary(candidate, fileManager: fileManager) {
                return candidate
            }
            let child = candidate.appending(path: "steamapps", directoryHint: .isDirectory)
            if isLibrary(child, fileManager: fileManager) { return child }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate { break }
            candidate = parent
        }
        return nil
    }

    /// A `steamapps` folder with Wallpaper Engine's Workshop manifest or content folder.
    static func isLibrary(_ steamapps: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: manifest(in: steamapps).path)
            || fileManager.fileExists(atPath: contentDirectory(in: steamapps).path)
    }

    static func manifest(in steamapps: URL) -> URL {
        steamapps.appending(path: "workshop/appworkshop_\(appID).acf")
    }

    static func contentDirectory(in steamapps: URL) -> URL {
        steamapps.appending(path: "workshop/content/\(appID)", directoryHint: .isDirectory)
    }

    /// The Steam libraries of CrossOver bottles:
    /// `~/Library/Application Support/CrossOver/Bottles/*/drive_c/Program Files (x86)/Steam/steamapps`
    /// (and `Program Files`), with any further libraries their `libraryfolders.vdf` lists inside
    /// the bottle.
    static func crossOverLibraries(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   fileManager: FileManager = .default) -> [URL] {
        let bottles = home.appending(path: "Library/Application Support/CrossOver/Bottles", directoryHint: .isDirectory)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: bottles.path).sorted()
        } catch {
            // No CrossOver: an optional lookup.
            return []
        }
        var found: [URL] = []
        for name in names where !name.hasPrefix(".") {
            let driveC = bottles.appending(path: "\(name)/drive_c", directoryHint: .isDirectory)
            for programFiles in ["Program Files (x86)", "Program Files"] {
                let steamapps = driveC.appending(path: "\(programFiles)/Steam/steamapps", directoryHint: .isDirectory)
                guard fileManager.fileExists(atPath: steamapps.path) else { continue }
                for library in [steamapps] + additionalLibraries(listedIn: steamapps, driveC: driveC, fileManager: fileManager)
                where isLibrary(library, fileManager: fileManager)
                    && !found.contains(where: { $0.standardizedFileURL.path == library.standardizedFileURL.path }) {
                    found.append(library)
                }
            }
        }
        return found
    }

    /// The other libraries `libraryfolders.vdf` names, as paths inside the bottle's `C:` drive.
    private static func additionalLibraries(listedIn steamapps: URL, driveC: URL, fileManager: FileManager) -> [URL] {
        let file = steamapps.appending(path: "libraryfolders.vdf")
        guard fileManager.fileExists(atPath: file.path) else { return [] }
        let root: [ValveKeyValues.Entry]
        do {
            root = try ValveKeyValues.parse(contentsOf: file)
        } catch {
            OWELog.error(.importer, "Can't read \(file.path): \(error.localizedDescription)")
            return []
        }
        let folders = root["libraryfolders"]?.entries ?? []
        return folders.compactMap { entry -> URL? in
            // Newer files: "0" { "path" "C:\\…" }; older ones: "1" "D:\\…".
            guard let path = entry.value["path"]?.string ?? entry.value.string else { return nil }
            let windows = path.replacingOccurrences(of: "\\\\", with: "\\")
            guard windows.count > 2, windows.lowercased().hasPrefix("c:") else { return nil }
            let relative = windows.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return driveC.appending(path: relative).appending(path: "steamapps", directoryHint: .isDirectory)
        }
    }

    // MARK: Reading the manifest

    /// The ids `appworkshop_431960.acf` lists: subscribed (`WorkshopItemDetails`) and installed
    /// (`WorkshopItemsInstalled`), in the file's order.
    static func manifestIDs(_ entries: [ValveKeyValues.Entry]) -> (subscribed: [String], installed: [String]) {
        let root = entries["AppWorkshop"] ?? .object(entries)
        let isID: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        let installed = (root["WorkshopItemsInstalled"]?.entries ?? []).map(\.key).filter(isID)
        let subscribed = (root["WorkshopItemDetails"]?.entries ?? []).map(\.key).filter(isID)
        return (subscribed, installed)
    }

    /// The items of a library whose folders are on disk: the manifest's ids, then any other
    /// folder in the content directory. Items without a readable project.json are logged and left out.
    static func items(in steamapps: URL, fileManager: FileManager = .default) throws -> [Item] {
        guard isLibrary(steamapps, fileManager: fileManager) else { throw Failure.notASteamLibrary(steamapps) }
        var subscribed: [String] = []
        var ordered: [String] = []
        let manifestURL = manifest(in: steamapps)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let ids = manifestIDs(try ValveKeyValues.parse(contentsOf: manifestURL))
            subscribed = ids.subscribed
            ordered = ids.subscribed + ids.installed.filter { !ids.subscribed.contains($0) }
        }
        let content = contentDirectory(in: steamapps)
        if fileManager.fileExists(atPath: content.path) {
            let folders = try fileManager.contentsOfDirectory(atPath: content.path).sorted()
            ordered += folders.filter { name in !ordered.contains(name) && name.allSatisfy(\.isNumber) && !name.isEmpty }
        }
        return ordered.compactMap { id -> Item? in
            let folder = content.appending(path: id, directoryHint: .isDirectory)
            guard fileManager.fileExists(atPath: WEProject.url(in: folder).path) else { return nil }
            do {
                return try item(id: id, folder: folder, isSubscribed: subscribed.contains(id))
            } catch {
                OWELog.error(.importer, "Workshop item \(id) in \(steamapps.path) skipped: its project.json doesn't read: \(error)")
                return nil
            }
        }
    }

    static func item(id: String, folder: URL, isSubscribed: Bool) throws -> Item {
        let data = TolerantJSON.withoutBOM(try WEProject.data(in: folder))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let title = (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let preview = (root["preview"] as? String).flatMap { name -> URL? in
            guard !name.isEmpty else { return nil }
            let url = folder.appending(path: name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        let tags = root["tags"] as? [String] ?? []
        let rating = (root["contentrating"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? InstalledWorkshopTags.contentRating(in: tags)
        return Item(id: id, folder: folder, title: title,
                    type: try WallpaperEngineDefaultProjects.type(ofProjectAt: folder),
                    preview: preview, contentRating: rating, isSubscribed: isSubscribed)
    }

    // MARK: Copying

    /// Copies each item to `<storage>/<id>`: through a hidden folder in the storage folder, renamed
    /// into place when complete, so a failed copy leaves nothing half-written. Application items
    /// and ids the storage folder already has are skipped.
    static func copy(_ items: [Item], into storage: URL, fileManager: FileManager = .default,
                     isCancelled: () -> Bool = { false }) -> CopyResult {
        var result = CopyResult()
        for item in items {
            if isCancelled() { break }
            guard item.isImportable else {
                result.unsupported.append(item.id)
                continue
            }
            let destination = storage.appending(path: item.id, directoryHint: .isDirectory)
            guard !fileManager.fileExists(atPath: destination.path) else {
                result.existing.append(item.id)
                continue
            }
            let staging = storage.appending(path: ".owe-import-\(item.id)", directoryHint: .isDirectory)
            do {
                if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
                guard !ContainedPath.isSymbolicLink(item.folder) else {
                    throw ImportedFolderLinks.FolderIsLinkError(path: item.folder.path)
                }
                try fileManager.copyItem(at: item.folder, to: staging)
                try ImportedFolderLinks.removeLinks(in: staging, fileManager: fileManager)
                try fileManager.moveItem(at: staging, to: destination)
                result.copied.append(item.id)
            } catch {
                OWELog.error(.importer, "Can't copy Workshop item \(item.id) from \(item.folder.path): \(error)")
                do {
                    if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
                } catch {
                    OWELog.error(.importer, "Can't remove the partial copy \(staging.path): \(error)")
                }
                result.failed.append(item.id)
            }
        }
        return result
    }
}
