import Foundation

/// Moves a file or folder to a new place without keeping both and without losing the newer data
/// (`AppIdentityMigration`).
///
/// - Nothing at the destination: one `moveItem`, an atomic rename on the same volume.
/// - A folder at both (a partial earlier run, or something the new identity wrote): each child is
///   merged the same way, then the emptied source folder is removed.
/// - A file at both: the newer one (modification date) stays at the destination, the other is
///   deleted. A tie keeps the destination's.
///
/// Running it again after a crash finishes what is left: whatever was moved is no longer at the
/// source.
struct FolderMerger {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Moves `source` to `destination`. Returns false when there was nothing at `source`.
    @discardableResult
    func move(_ source: URL, to destination: URL) throws -> Bool {
        guard let sourceIsFolder = kind(of: source) else { return false }
        guard let destinationIsFolder = kind(of: destination) else {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return true
        }
        if sourceIsFolder && destinationIsFolder {
            for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                try move(child, to: destination.appending(path: child.lastPathComponent))
            }
            try fileManager.removeItem(at: source)
        } else if try modificationDate(of: source) > modificationDate(of: destination) {
            // Replaces the older destination in one step, so a crash leaves one of the two.
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.removeItem(at: source)
        }
        return true
    }

    /// true for a folder, false for anything else, nil when nothing is there. A symbolic link is
    /// not followed: it is moved as itself.
    private func kind(of url: URL) -> Bool? {
        let path = url.path(percentEncoded: false)
        do {
            let type = try fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            return type == .typeDirectory
        } catch {
            // Nothing there (or unreadable, which the move then reports).
            return fileManager.fileExists(atPath: path) ? false : nil
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try fileManager.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attributes[.modificationDate] as? Date ?? .distantPast
    }
}
