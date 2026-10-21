import Darwin
import Foundation

/// macOS's Metal shader cache of this app, `<Darwin user cache>/<bundle id>/com.apple.metal`
/// (`DarwinUserDirectories`): compiled GPU functions Metal keeps per process identity. OWE never
/// reads it; it only deletes it, whole, at launch (`prepareForLaunch`) when keeping it would hurt:
///
/// - **The shaders changed.** The stamp (`MetalShaderCacheLaunch.stamp`: `ShaderVariantTranslator
///   .revision` and `EffectPipelineArchive.revision`) differs from the last launch's (`stampFile`;
///   no stamp yet counts as changed). Everything Metal
///   cached for the old translations is dead weight it never evicts.
/// - **Metal's usage database is full.** Its LMDB file (`archiveUsage.db`, 1 MiB map) is at the
///   map's size (`LMDBEnvironmentUsage`), so the last session logged `MDB_MAP_FULL` and Metal can't
///   record anything new.
/// - **Clear Caches asked for it** (`requestReset`, `requestFile`): the running app holds the cache
///   open, so Settings' button clears it on the next launch.
///
/// Only this process's own folder is touched, and only while no other OWE process uses it: every
/// OWE process holds a shared `flock` on `lockFile` from its start (`prepareForLaunch`) for as
/// long as it runs, and a reset needs the exclusive lock. Builds from before the lock existed
/// don't take it, so a reset also waits while another process with this bundle id runs
/// (`siblingsRunning`). A reset that has to wait is kept for the next launch.
struct MetalShaderCache {
    /// `com.apple.metal`.
    let directory: URL

    var container: URL { directory.deletingLastPathComponent() }
    var lockFile: URL { container.appending(path: "owe-metal-cache.lock") }
    var stampFile: URL { container.appending(path: "owe-metal-cache.revision") }
    var requestFile: URL { container.appending(path: "owe-metal-cache.reset-requested") }

    init(directory: URL) {
        self.directory = directory
    }

    /// This process's cache: `<Darwin user cache>/<bundle id>/com.apple.metal`; nil without either.
    static var current: MetalShaderCache? {
        guard let root = DarwinUserDirectories.cacheDirectory, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return MetalShaderCache(directory: root.appending(path: "\(bundleID)/com.apple.metal", directoryHint: .isDirectory))
    }

    enum ResetReason: Equatable {
        case revisionChanged(from: String?)
        case usageDatabaseFull(String)
        case requested
    }

    /// Why the cache should go now, or nil to keep it. `stamp` names what the app's shaders are
    /// now (`MetalShaderCacheLaunch.stamp`).
    func resetReason(stamp: String) -> ResetReason? {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: requestFile.path(percentEncoded: false)) { return .requested }
        guard fileManager.fileExists(atPath: directory.path(percentEncoded: false)) else { return nil }
        let previous = Self.readStamp(stampFile)
        if previous != stamp { return .revisionChanged(from: previous) }
        if let full = fullUsageDatabase() { return .usageDatabaseFull(full) }
        return nil
    }

    /// The name of an LMDB database in the cache that is full, or nil.
    func fullUsageDatabase() -> String? {
        // Optional: an empty or missing cache has no database.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names.sorted() where name.hasSuffix(".db") {
            let data = directory.appending(path: name, directoryHint: .isDirectory).appending(path: "data.mdb")
            if let usage = LMDBEnvironmentUsage.read(dataFile: data), usage.isNearlyFull { return name }
        }
        return nil
    }

    /// Clear Caches: the cache goes at the next launch.
    func requestReset() throws {
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data().write(to: requestFile, options: .atomic)
    }

    /// The bytes the cache takes on disk.
    func allocatedSize() -> Int64 { CacheFolderSize.allocatedSize(of: directory) }

    // MARK: Launch

    enum LaunchOutcome: Equatable {
        case kept
        case reset(ResetReason)
        /// A reset was due but another OWE process uses the cache; it waits for the next launch.
        case deferred(ResetReason)
        case unavailable
    }

    /// Resets the cache when due (and `mayReset`) and no other OWE process uses it, then takes
    /// this process's shared lock on it for as long as `lock` lives. Call before any Metal work.
    func prepareForLaunch(lock: MetalShaderCacheLock, stamp: String, mayReset: Bool = true,
                          siblingsRunning: () -> Bool) -> LaunchOutcome {
        do {
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        } catch {
            OWELog.error(.app, "Metal shader cache: can't create \(container.path): \(error)")
            return .unavailable
        }
        guard lock.open(lockFile) else { return .unavailable }
        defer { lock.share() }
        guard mayReset else { return .kept }
        discardLeftovers()
        let reason = resetReason(stamp: stamp)
        guard let reason else {
            writeStamp(stamp)
            return .kept
        }
        guard lock.tryExclusive(), !siblingsRunning() else { return .deferred(reason) }
        guard reset() else { return .deferred(reason) }
        writeStamp(stamp)
        do {
            try FileManager.default.removeItem(at: requestFile)
        } catch CocoaError.fileNoSuchFile {
            // No request: the reset had another reason.
        } catch {
            OWELog.error(.app, "Metal shader cache: can't remove \(requestFile.lastPathComponent): \(error)")
        }
        return .reset(reason)
    }

    /// Moves the cache aside (one rename, so Metal never sees half of it) and deletes it.
    private func reset() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else { return true }
        let discarded = container.appending(path: "com.apple.metal.owe-discard-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.moveItem(at: directory, to: discarded)
        } catch {
            OWELog.error(.app, "Metal shader cache: can't move \(directory.path) aside: \(error)")
            return false
        }
        remove(discarded)
        return true
    }

    /// Folders an earlier reset moved aside but didn't finish deleting.
    private func discardLeftovers() {
        // Optional: no container listing, no leftovers.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: container.path(percentEncoded: false))) ?? []
        for name in names where name.hasPrefix("com.apple.metal.owe-discard-") {
            remove(container.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            OWELog.error(.app, "Metal shader cache: can't delete \(url.path): \(error)")
        }
    }

    private static func readStamp(_ url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            OWELog.error(.app, "Metal shader cache: can't read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    private func writeStamp(_ stamp: String) {
        guard Self.readStamp(stampFile) != stamp else { return }
        do {
            try Data(stamp.utf8).write(to: stampFile, options: .atomic)
        } catch {
            OWELog.error(.app, "Metal shader cache: can't write \(stampFile.lastPathComponent): \(error)")
        }
    }
}
