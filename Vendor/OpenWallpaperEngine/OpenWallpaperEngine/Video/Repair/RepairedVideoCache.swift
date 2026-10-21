import CryptoKit
import Foundation

/// The repaired copies of videos AVFoundation refuses (`VideoSampleEntryRepair`), kept in the
/// app's caches so the wallpaper's own folder, which may be a Steam or linked folder, is never
/// written: `<Caches>/Open Wallpaper Engine/RepairedVideos/r<revision>/<source key>/<size>-<mtime>.<ext>`.
/// A source that changes (size or modification time) gets a new copy, and the old one is removed.
/// Each source's folder also holds `.source`, the source's path, so deleting a wallpaper removes
/// its copies (`removeCopies(forSourcesIn:)`). Serving a copy marks it used (`CacheEntryUse`), and
/// copies unused for 60 days expire (`CacheSweeper`).
struct RepairedVideoCache {
    /// Bump whenever `VideoSampleEntryRepair` writes different bytes.
    static let revision = 1
    /// Containers the repair reads; anything else (WebM) is played as it is.
    static let repairableExtensions: Set<String> = ["mp4", "m4v", "mov"]

    let directory: URL

    static var current: RepairedVideoCache {
        RepairedVideoCache(cachesDirectory: AppStorageLocation.current.cachesDirectory)
    }

    /// The source's path, in each source's folder.
    static let sourceFileName = ".source"

    init(cachesDirectory: URL) {
        directory = Self.root(in: cachesDirectory).appending(path: "r\(Self.revision)", directoryHint: .isDirectory)
    }

    /// `<Caches>/Open Wallpaper Engine/RepairedVideos`, every revision's parent.
    static func root(in cachesDirectory: URL) -> URL {
        cachesDirectory.appending(path: "Open Wallpaper Engine/RepairedVideos", directoryHint: .isDirectory)
    }

    /// Whether `source` is a local file the repair could apply to.
    static func mayNeedRepair(_ source: URL) -> Bool {
        source.isFileURL && repairableExtensions.contains(source.pathExtension.lowercased())
    }

    /// Where the repaired copy of `source` as it is now belongs, or nil when its attributes can't
    /// be read.
    func copyURL(for source: URL) -> URL? {
        let path = source.standardizedFileURL.path(percentEncoded: false)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            OWELog.error(.library, "Can't read \(source.lastPathComponent) to check its video track: \(error.localizedDescription)")
            return nil
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = Digest.hex(SHA256.hash(data: Data(path.utf8)).prefix(12))
        let name = "\(size)-\(Int64(modified * 1_000_000)).\(source.pathExtension.lowercased())"
        return directory.appending(path: key, directoryHint: .isDirectory).appending(path: name)
    }

    /// The file AVFoundation should open for `source`: its repaired copy, made now when missing,
    /// or `source` itself when it needs no repair or the repair fails (the failure is logged).
    /// `willRepair` is called before a copy is written. Reads the file: never call it on the main
    /// or render thread.
    func playableURL(for source: URL, willRepair: () -> Void = {}) -> URL {
        guard Self.mayNeedRepair(source), let copy = copyURL(for: source) else { return source }
        if FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)) {
            CacheEntryUse.markUsed(copy)
            // A copy made before `.source` existed gets it now.
            let record = copy.deletingLastPathComponent().appending(path: Self.sourceFileName)
            if !FileManager.default.fileExists(atPath: record.path(percentEncoded: false)) { recordSource(source, of: copy) }
            return copy
        }
        do {
            guard try VideoSampleEntryRepair.needsRepair(source) else { return source }
            willRepair()
            let started = Date()
            guard try VideoSampleEntryRepair.repair(source, to: copy) else { return source }
            removeOlderCopies(besides: copy)
            recordSource(source, of: copy)
            OWELog.info(.library, "Repaired the in-band parameter sets of \(source.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            return copy
        } catch {
            OWELog.error(.library, "Can't repair \(source.path(percentEncoded: false)) for AVFoundation; playing the original: \(error)")
            return source
        }
    }

    /// Removes the copies made for earlier versions of the same source.
    private func removeOlderCopies(besides copy: URL) {
        let folder = copy.deletingLastPathComponent()
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        } catch {
            OWELog.error(.library, "Can't list \(folder.path(percentEncoded: false)): \(error.localizedDescription)")
            return
        }
        for entry in entries where entry.lastPathComponent != copy.lastPathComponent && !entry.lastPathComponent.hasSuffix(".partial")
            && entry.lastPathComponent != Self.sourceFileName {
            do {
                try FileManager.default.removeItem(at: entry)
            } catch {
                OWELog.error(.library, "Can't remove the old repaired video \(entry.path(percentEncoded: false)): \(error.localizedDescription)")
            }
        }
    }

    /// Writes the source's path next to its copy.
    private func recordSource(_ source: URL, of copy: URL) {
        let file = copy.deletingLastPathComponent().appending(path: Self.sourceFileName)
        do {
            try Data(source.standardizedFileURL.path(percentEncoded: false).utf8).write(to: file, options: .atomic)
        } catch {
            OWELog.error(.library, "Can't record the source of the repaired video \(copy.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Removes the copies of every source inside `folder` (a deleted wallpaper's), in every
    /// revision. Copies made before `.source` existed expire with the unused ones instead.
    /// Blocking file IO: call it off the main thread.
    func removeCopies(forSourcesIn folder: URL) {
        ThreadGuards.assertNotMainThread("RepairedVideoCache.removeCopies")
        let prefix = folder.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") + "/"
        let fileManager = FileManager.default
        let root = directory.deletingLastPathComponent()
        // Optional: no cache yet, nothing to remove.
        let revisions = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for revision in revisions {
            let sources = (try? fileManager.contentsOfDirectory(at: revision, includingPropertiesForKeys: nil)) ?? [] // Optional, as above.
            for source in sources {
                let record = source.appending(path: Self.sourceFileName)
                guard fileManager.fileExists(atPath: record.path(percentEncoded: false)) else { continue }
                let path: String
                do {
                    path = try String(contentsOf: record, encoding: .utf8)
                } catch {
                    OWELog.error(.library, "Can't read \(record.path(percentEncoded: false)): \(error.localizedDescription)")
                    continue
                }
                guard path.hasPrefix(prefix) else { continue }
                do {
                    try fileManager.removeItem(at: source)
                    OWELog.info(.library, "Removed the repaired copy of \((path as NSString).lastPathComponent): its wallpaper was deleted")
                } catch {
                    OWELog.error(.library, "Can't remove the repaired video \(source.path(percentEncoded: false)): \(error.localizedDescription)")
                }
            }
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var text = self
        while text.count > 1, text.hasSuffix(suffix) { text.removeLast(suffix.count) }
        return text
    }
}
