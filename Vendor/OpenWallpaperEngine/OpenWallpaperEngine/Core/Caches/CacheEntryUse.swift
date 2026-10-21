import Foundation

/// The last use of an entry in OWE's own caches is its file's modification date: every cache
/// sets it when it writes an entry and calls `markUsed` when it serves one. `CacheSweeper` deletes
/// entries whose date is older than `CacheSweeper.unusedLifetime`. Entries never change after
/// they are written (each cache's name says what the content is), so the date has no other use.
/// The date is moved at most once per `resolution`, so serving an entry costs one `stat`.
enum CacheEntryUse {
    static let resolution: TimeInterval = 24 * 3600

    /// Marks the file at `url` used now. Blocking file IO: call it off the main thread.
    static func markUsed(_ url: URL, now: Date = Date()) {
        let path = url.path(percentEncoded: false)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let modified = attributes[.modificationDate] as? Date, now.timeIntervalSince(modified) < resolution { return }
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
        } catch {
            OWELog.debug(.app, "Cache: can't mark \(url.lastPathComponent) used: \(error)")
        }
    }
}
