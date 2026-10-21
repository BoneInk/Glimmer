import Foundation

/// Deletes entries of OWE's own caches (`CacheFolder`):
///
/// - `expire`: every entry of an expiring cache whose last use (`CacheEntryUse`, its modification
///   date) is older than `unusedLifetime`.
/// - `clear`: every entry (Settings' Clear Caches).
///
/// Neither touches a leased path (`CacheLeases`: what a wallpaper on screen, a player or a renderer
/// uses now) or anything under `protected` (e.g. the Wallpaper Editor's previews while it runs).
/// Hidden files are bookkeeping (a repaired video's `.source`, the editor previews' `.inputs.json`,
/// a blob being written): they go with their folder once it holds nothing else, and a stray
/// `.tmp` once it is older than `unusedLifetime`. Folders left empty are removed; the caches'
/// roots stay. Blocking file IO: run it in the background.
struct CacheSweeper {
    static let unusedLifetime: TimeInterval = 60 * 24 * 3600

    let folders: [CacheFolder]
    var leases: CacheLeases = .current
    var protected: [URL] = []

    struct Result: Equatable {
        var removedFiles = 0
        var removedBytes: Int64 = 0

        static func + (a: Result, b: Result) -> Result {
            Result(removedFiles: a.removedFiles + b.removedFiles, removedBytes: a.removedBytes + b.removedBytes)
        }
    }

    @discardableResult
    func expire(now: Date = Date()) -> Result {
        ThreadGuards.assertBackground("CacheSweeper.expire")
        let cutoff = now.addingTimeInterval(-Self.unusedLifetime)
        return folders.filter(\.expires).reduce(Result()) { $0 + sweep($1) { $0 < cutoff } }
    }

    @discardableResult
    func clear() -> Result {
        ThreadGuards.assertBackground("CacheSweeper.clear")
        return folders.reduce(Result()) { $0 + sweep($1) { _ in true } }
    }

    /// Each cache's bytes on disk.
    func sizes() -> [CacheFolder.ID: Int64] {
        Dictionary(folders.map { ($0.id, CacheFolderSize.allocatedSize(of: $0.root)) }, uniquingKeysWith: +)
    }

    // MARK: -

    private func sweep(_ folder: CacheFolder, removes: (Date) -> Bool) -> Result {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey,
                                      .totalFileAllocatedSizeKey, .isHiddenKey]
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: folder.root.path(percentEncoded: false)),
              let enumerator = fileManager.enumerator(at: folder.root, includingPropertiesForKeys: keys,
                                                      errorHandler: { _, _ in true }) else { return Result() }
        let leased = leases.paths
        let protectedPaths = Set(protected.map(CacheLeases.key))
        var result = Result()
        var folders: [URL] = []
        let tmpCutoff = Date().addingTimeInterval(-Self.unusedLifetime)
        for case let url as URL in enumerator {
            // Optional: an entry removed while listing needs nothing.
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = CacheLeases.key(url)
            if values.isDirectory == true {
                if CacheLeases.isCovered(path, by: protectedPaths) {
                    enumerator.skipDescendants()
                } else {
                    folders.append(url)
                }
                continue
            }
            guard values.isRegularFile == true, folder.isEntry(named: url.lastPathComponent) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            if url.lastPathComponent.hasPrefix(".") {
                guard url.pathExtension == "tmp", modified < tmpCutoff else { continue }
            } else {
                guard removes(modified) else { continue }
            }
            guard !CacheLeases.isCovered(path, by: leased), !CacheLeases.isCovered(path, by: protectedPaths) else { continue }
            if remove(url) {
                result.removedFiles += 1
                result.removedBytes += Int64(values.totalFileAllocatedSize ?? 0)
            }
        }
        // Deepest first, so a folder emptied by its subfolders' removal goes too.
        for url in folders.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
            removeIfOnlyBookkeeping(url, leased: leased)
        }
        return result
    }

    /// Removes `folder` when it holds only hidden files (or nothing) and nothing in it is leased.
    private func removeIfOnlyBookkeeping(_ folder: URL, leased: Set<String>) {
        // Optional: a folder that can't be listed stays.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)),
              names.allSatisfy({ $0.hasPrefix(".") }),
              !CacheLeases.isCovered(CacheLeases.key(folder), by: leased) else { return }
        remove(folder)
    }

    @discardableResult
    private func remove(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch CocoaError.fileNoSuchFile {
            return false // Another process removed it first.
        } catch {
            OWELog.error(.app, "Cache: can't delete \(url.path(percentEncoded: false)): \(error.localizedDescription)")
            return false
        }
    }
}
