import Foundation

/// The copy of the Wallpaper Engine assets the app keeps in the Wallpaper Storage folder
/// (`<storage>/.owe-assets`), taken from a Wallpaper Engine install: the user's Steam copy
/// downloaded with SteamCMD, or an install folder on disk.
///
/// Only what wallpapers and the Wallpaper Editor use is kept: the effect manifests (without editor
/// preview projects), the GLSL shaders and shared headers (without Direct3D or editor shaders),
/// materials, models, particles, the editor's particle presets (without their preview projects),
/// the SceneScript runtime, the compatibility patches, the built-in fonts with their licence files,
/// the UI strings (`<install>/locale/ui_*.json`, beside `assets`) that translate label keys, the
/// script editor's snippets (`<install>/ui/dist/monaco/snippets/*.js`, into `snippets`), and
/// WE's project templates for New Wallpaper (`<install>/projects/templates`, into `templates`).
enum WallpaperEngineAssetsCache {
    /// What the cache was filled from, stored beside it.
    struct Info: Codable, Equatable {
        enum Origin: String, Codable {
            case steam
            case folder
        }

        var origin: Origin
        var installedAt: Date
        /// Steam's build id of the Wallpaper Engine copy, when it came from Steam.
        var steamBuildID: String?
        /// The default wallpapers brought into the storage folder with the assets, by folder name,
        /// so removing the assets can offer to remove them too.
        var defaultProjects: [String]?
    }

    enum Failure: LocalizedError {
        case notAnInstall(URL)

        var errorDescription: String? {
            switch self {
            case .notAnInstall(let url):
                return String(localized: "\(url.path) isn't a Wallpaper Engine folder or its assets folder.",
                              comment: "Assets error; %@ is a folder path")
            }
        }
    }

    /// The folders copied whole, besides `effects`, `presets` and `shaders`.
    static let wholeFolders = ["fonts", "materials", "models", "particles", "scripts", "zcompat"]
    /// The folders copied without some of their files (`isExcluded`).
    static let filteredFolders = ["effects", "presets", "shaders"]
    static let infoFileName = ".owe-assets-info.json"
    /// WE's project templates, relative to the install, and the cache's copy of them.
    static let installTemplatesPath = "projects/templates"
    static let templatesFolder = "templates"
    /// Where WE's editor keeps its script and shader snippets, relative to the install.
    static let installSnippetsPath = "ui/dist/monaco/snippets"
    /// The cache's copy of them.
    static let snippetsFolder = "snippets"

    static func infoURL(cache: URL) -> URL { cache.appending(path: infoFileName) }

    static func readInfo(cache: URL) -> Info? {
        let url = infoURL(cache: cache)
        // An absent file is a cache without history (or no cache): no info to show.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Info.self, from: Data(contentsOf: url))
        } catch {
            OWELog.error(.library, "Can't read the assets cache's info at \(url.path): \(error)")
            return nil
        }
    }

    static func writeInfo(_ info: Info, cache: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: infoURL(cache: cache), options: .atomic)
    }

    /// Whether a path relative to `effects/`, `presets/` or `shaders/` is left out: an effect's
    /// or preset's preview projects (`preview/`, `previewdownpour/`), which WE's editor plays and
    /// this app doesn't (it renders its own previews), and the shaders it doesn't translate.
    static func isExcluded(_ relativePath: String, in folder: String) -> Bool {
        let components = relativePath.split(separator: "/").map { String($0) }
        if components.last == ".DS_Store" { return true }
        let directories = components.dropLast()
        switch folder {
        case "effects", "presets":
            return directories.contains { $0.lowercased().hasPrefix("preview") }
        case "shaders":
            return directories.contains { $0 == "HLSL" || $0 == "editor" }
        default:
            return false
        }
    }

    /// Replaces the cache at `cache` with the assets of `install` (an install or its `assets`
    /// folder). The new copy is built beside the old one and swapped in, so a failure or a
    /// cancellation leaves the previous cache as it was.
    @discardableResult
    static func fill(_ cache: URL, from install: URL, info: Info, isCancelled: () -> Bool = { false },
                     fileManager: FileManager = .default) throws -> Int {
        let assets = WallpaperEngineAssets.assetsFolder(of: install, fileManager: fileManager)
        guard WallpaperEngineAssets.isAssetTree(assets, fileManager: fileManager) else { throw Failure.notAnInstall(install) }
        let staging = cache.deletingLastPathComponent().appending(path: cache.lastPathComponent + ".partial",
                                                                  directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        do {
            var count = 0
            for folder in filteredFolders + wholeFolders {
                count += try copyTree(assets.appending(path: folder), to: staging.appending(path: folder),
                                      folder: folder, isCancelled: isCancelled, fileManager: fileManager)
            }
            let locale = assets.deletingLastPathComponent().appending(path: "locale")
            if fileManager.fileExists(atPath: locale.path) {
                let strings = try fileManager.contentsOfDirectory(atPath: locale.path)
                    .filter { $0.hasPrefix("ui_") && $0.hasSuffix(".json") }
                let destination = staging.appending(path: "locale")
                if !strings.isEmpty { try fileManager.createDirectory(at: destination, withIntermediateDirectories: true) }
                for name in strings {
                    try fileManager.copyItem(at: locale.appending(path: name), to: destination.appending(path: name))
                    count += 1
                }
            }
            let templates = assets.deletingLastPathComponent().appending(path: installTemplatesPath, directoryHint: .isDirectory)
            // An assets folder alone has no templates to keep.
            if fileManager.fileExists(atPath: templates.path) {
                count += try copyTree(templates, to: staging.appending(path: templatesFolder), folder: templatesFolder,
                                      isCancelled: isCancelled, fileManager: fileManager)
            }
            count += try copySnippets(of: assets.deletingLastPathComponent(), to: staging, fileManager: fileManager)
            try checkCancelled(isCancelled)
            try writeInfo(info, cache: staging)
            if fileManager.fileExists(atPath: cache.path) { try fileManager.removeItem(at: cache) }
            try fileManager.moveItem(at: staging, to: cache)
            return count
        } catch {
            removeIfPresent(staging, fileManager: fileManager)
            throw error
        }
    }

    /// The script editor's snippets of the install `root` (none in an assets folder alone).
    private static func copySnippets(of root: URL, to staging: URL, fileManager: FileManager) throws -> Int {
        let snippets = root.appending(path: installSnippetsPath, directoryHint: .isDirectory)
        // An assets folder alone, or a WE copy without the editor's UI: no snippets to keep.
        guard fileManager.fileExists(atPath: snippets.path) else { return 0 }
        let names = try fileManager.contentsOfDirectory(atPath: snippets.path).filter { $0.hasSuffix(".js") }
        guard !names.isEmpty else { return 0 }
        let destination = staging.appending(path: snippetsFolder, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in names {
            try fileManager.copyItem(at: snippets.appending(path: name), to: destination.appending(path: name))
        }
        return names.count
    }

    /// Copies the files of `source` into `destination`, creating only folders that get a file.
    private static func copyTree(_ source: URL, to destination: URL, folder: String, isCancelled: () -> Bool,
                                 fileManager: FileManager) throws -> Int {
        guard fileManager.fileExists(atPath: source.path) else { return 0 }
        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        let base = source.standardizedFileURL.path + "/"
        var count = 0
        for case let file as URL in enumerator {
            let isFile: Bool = try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false
            guard isFile else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(base.count))
            guard !isExcluded(relative, in: folder) else { continue }
            try checkCancelled(isCancelled)
            let target = destination.appending(path: relative)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: file, to: target)
            count += 1
        }
        return count
    }

    private static func checkCancelled(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw CancellationError() }
    }

    /// Deletes a folder the app created itself (a staging copy or a finished download).
    static func removeIfPresent(_ url: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            OWELog.error(.library, "Can't remove \(url.path): \(error)")
        }
    }

    /// The bytes `directory` takes on disk.
    static func size(of directory: URL, fileManager: FileManager = .default) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            do {
                let values = try file.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? 0)
            } catch {
                OWELog.error(.library, "Can't size \(file.path): \(error)")
            }
        }
        return total
    }
}
