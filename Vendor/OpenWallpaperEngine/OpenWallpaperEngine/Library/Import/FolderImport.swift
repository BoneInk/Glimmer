import Foundation

/// Import › From Folder's work, shared by the panel and the MCP Server plugin's import_wallpaper:
/// the wallpaper folders (with a project.json) and zips among what was chosen, a folder of
/// wallpaper folders counting as its wallpapers, copied into the library folder.
enum FolderImport {
    struct Sources: Equatable {
        var folders: [URL] = []
        var zips: [URL] = []

        var isEmpty: Bool { folders.isEmpty && zips.isEmpty }
    }

    struct Outcome: Equatable {
        /// The wallpapers' new folders in the library.
        var imported: [URL] = []
        /// What was left out, with why.
        var skipped: [Skip] = []
    }

    struct Skip: Equatable {
        var source: URL
        var reason: Reason
    }

    enum Reason: Equatable {
        /// The library has a folder of that name already.
        case alreadyInLibrary
        case copyFailed(String)
        /// A zip with no wallpaper in it.
        case noWallpaper
    }

    /// The wallpapers among `urls`: zips, folders with a project.json, and those folders' child
    /// folders with one.
    static func sources(in urls: [URL], fileManager: FileManager = .default) -> Sources {
        var sources = Sources()
        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                sources.zips.append(url)
            } else if fileManager.fileExists(atPath: WEProject.url(in: url).path) {
                sources.folders.append(url)
            } else {
                // A folder that can't be listed has no wallpapers to offer; the empty result says so.
                guard let children = try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { continue }
                for child in children {
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue,
                       fileManager.fileExists(atPath: WEProject.url(in: child).path) {
                        sources.folders.append(child)
                    }
                }
            }
        }
        return sources
    }

    /// Copies `sources` into `library` and starts preparing each copy in the background
    /// (`WallpaperPreparation`, a zip's by `ZipImporter`). Blocking file IO.
    @discardableResult
    static func importWallpapers(_ sources: Sources, into library: URL, fileManager: FileManager = .default,
                                 prepare: @escaping @Sendable (URL) -> Void = { WallpaperPreparation.prepare(wallpaperDirectory: $0) }) -> Outcome {
        var outcome = Outcome()
        for url in sources.folders {
            let destination = library.appending(path: url.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                outcome.skipped.append(Skip(source: url, reason: .alreadyInLibrary))
                continue
            }
            do {
                try ImportedFolderLinks.copyWithoutLinks(from: url, to: destination)
            } catch {
                OWELog.error(.importer, "Can't import \(url.path): \(error)")
                outcome.skipped.append(Skip(source: url, reason: .copyFailed(error.localizedDescription)))
                continue
            }
            outcome.imported.append(destination)
            DispatchQueue.global(qos: .utility).async { prepare(destination) }
        }
        for url in sources.zips {
            let before = folderNames(in: library, fileManager: fileManager)
            if ZipImporter.importZip(at: url, into: library) == 0 {
                outcome.skipped.append(Skip(source: url, reason: .noWallpaper))
            }
            let added = folderNames(in: library, fileManager: fileManager).subtracting(before)
            outcome.imported += added.sorted().map { library.appending(path: $0, directoryHint: .isDirectory) }
        }
        return outcome
    }

    private static func folderNames(in library: URL, fileManager: FileManager) -> Set<String> {
        do {
            return Set(try fileManager.contentsOfDirectory(atPath: library.path))
        } catch {
            OWELog.error(.importer, "Can't list the library at \(library.path): \(error)")
            return []
        }
    }
}
