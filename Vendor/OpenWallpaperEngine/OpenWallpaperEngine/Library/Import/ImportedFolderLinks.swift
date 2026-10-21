import Foundation

/// Imported wallpaper folders keep only their own files: symbolic links inside a folder that
/// comes from outside the library (a zip, a chosen folder, a Steam library) are removed before
/// the folder is converted or used.
enum ImportedFolderLinks {
    /// The imported folder is a symbolic link itself.
    struct FolderIsLinkError: Error {
        let path: String
    }

    /// Removes every symbolic link under `folder`. Throws when `folder` is a link itself, or when
    /// a link can't be removed. Returns how many were removed.
    @discardableResult
    static func removeLinks(in folder: URL, fileManager: FileManager = .default) throws -> Int {
        guard !ContainedPath.isSymbolicLink(folder) else { throw FolderIsLinkError(path: folder.path) }
        // The enumerator doesn't descend into linked folders, so every link is found where it sits.
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                      options: []) else { return 0 }
        var links: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true { links.append(url) }
        }
        for link in links {
            try fileManager.removeItem(at: link)
        }
        if !links.isEmpty {
            OWELog.info(.importer, "Removed \(links.count) symbolic link(s) from imported folder \(folder.lastPathComponent)")
        }
        return links.count
    }

    /// Copies the wallpaper folder `source` to `destination` without its symbolic links: through
    /// a hidden folder next to `destination`, renamed into place once the links are gone.
    static func copyWithoutLinks(from source: URL, to destination: URL, fileManager: FileManager = .default) throws {
        guard !ContainedPath.isSymbolicLink(source) else { throw FolderIsLinkError(path: source.path) }
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".owe-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: source, to: staging)
            try removeLinks(in: staging, fileManager: fileManager)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch let cleanup {
                    OWELog.error(.importer, "Can't remove the partial copy \(staging.path): \(cleanup)")
                }
            }
            throw error
        }
    }
}
