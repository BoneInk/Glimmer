import Foundation

/// Deleting installed wallpapers' folders, or moving them to the Trash.
enum WallpaperDeletion {
    /// Wallpapers that couldn't be deleted, shown in the library's alert with the system's reasons.
    struct Failure: LocalizedError {
        let reasons: [String]

        var errorDescription: String? {
            String(localized: "Couldn't Delete Wallpaper", comment: "Alert title: deleting or trashing a wallpaper failed")
        }

        var failureReason: String? { reasons.joined(separator: "\n") }
    }

    /// Deletes each folder, or moves it to the Trash: file IO, so never on the main thread.
    /// Returns the folders that are gone, and the failure when any isn't.
    ///
    /// A wallpaper listed through a symbolic link in one of `libraries` runs from the folder the
    /// link points to (`WEWallpaper`); deleting it removes the link, never that folder, which may
    /// be anywhere (another library, a Steam folder).
    static func delete(_ directories: [URL], toTrash: Bool, libraries: [URL] = [],
                       fileManager: FileManager = .default) -> (deleted: [URL], failure: Failure?) {
        ThreadGuards.assertBackground("wallpaper deletion")
        let links = linkEntries(in: libraries, fileManager: fileManager)
        var deleted: [URL] = []
        var reasons: [String] = []
        for directory in directories {
            let entry = ContainedPath.canonical(directory).flatMap { links[$0] } ?? directory
            do {
                if toTrash {
                    try fileManager.trashItem(at: entry, resultingItemURL: nil)
                } else {
                    try fileManager.removeItem(at: entry)
                }
                deleted.append(directory)
            } catch {
                OWELog.error(.library, "Can't \(toTrash ? "trash" : "delete") the wallpaper at \(directory.path): \(error)")
                reasons.append(error.localizedDescription)
            }
        }
        return (deleted, reasons.isEmpty ? nil : Failure(reasons: reasons))
    }

    /// The symbolic links directly in `libraries`, by the canonical path of the folder each points to.
    static func linkEntries(in libraries: [URL], fileManager: FileManager = .default) -> [String: URL] {
        var links: [String: URL] = [:]
        for library in libraries {
            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(at: ContainedPath.followingFolderLink(library),
                                                              includingPropertiesForKeys: [.isSymbolicLinkKey])
            } catch {
                // A library folder that is gone or unreadable holds no links to follow.
                OWELog.debug(.library, "Can't list \(library.path) for linked wallpapers: \(error)")
                continue
            }
            for entry in entries where ContainedPath.isSymbolicLink(entry) {
                if let target = ContainedPath.canonical(entry), links[target] == nil { links[target] = entry }
            }
        }
        return links
    }
}
