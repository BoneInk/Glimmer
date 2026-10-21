import AppKit
import Foundation

/// Keeps OWE's caches from growing without bound, and Settings' Clear Caches:
///
/// - **Unused entries expire.** `launchDelay` after launch, then about once a day in the
///   background (`NSBackgroundActivityScheduler`, which runs it when the Mac is idle enough), every
///   entry unused for 60 days goes (`CacheSweeper.expire`): texture blobs, loading snapshots,
///   editor previews, scene video textures and repaired videos. What the wallpapers on screen use
///   is leased (`CacheLeases`) and stays; so do the previews of the WE assets in use, which the
///   background pre-warm (`EditorPreviewPrewarm`) would only render again.
/// - **Clear Caches** (`clearAll`) deletes every entry of every cache except the leased ones, and
///   the editor's previews while the Wallpaper Editor runs, and asks for the Metal shader cache to
///   be deleted at the next launch (`MetalShaderCache.requestReset`): this process has it open.
@MainActor
final class CacheMaintenance {
    static let launchDelay: TimeInterval = 120
    static let interval: TimeInterval = 24 * 3600

    private var scheduler: NSBackgroundActivityScheduler?
    private var launchWork: DispatchWorkItem?

    init() {}

    func start() {
        let work = DispatchWorkItem { Self.expireInBackground(reason: "launch") }
        launchWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.launchDelay, execute: work)
        // An isolated copy's activity is its own (its caches are too).
        let tag = AppStorageLocation.current.isolationTag.map { ".isolated.\($0)" } ?? ""
        let scheduler = NSBackgroundActivityScheduler(identifier: "\(AppStorageLocation.realBundleIdentifier)\(tag).cache-expiry")
        scheduler.repeats = true
        scheduler.interval = Self.interval
        scheduler.tolerance = Self.interval / 4
        scheduler.qualityOfService = .background
        scheduler.schedule { completion in
            Self.expireInBackground(reason: "daily")
            completion(.finished)
        }
        self.scheduler = scheduler
    }

    func stop() {
        launchWork?.cancel()
        scheduler?.invalidate()
        scheduler = nil
    }

    // MARK: Expiry

    nonisolated private static func expireInBackground(reason: String) {
        let result = CacheSweeper(folders: CacheFolder.current, protected: expiryProtected()).expire()
        guard result.removedFiles > 0 else { return }
        OWELog.info(.app, "Caches (\(reason)): removed \(result.removedFiles) entries unused for 60 days, "
                    + ByteCountFormatter.string(fromByteCount: result.removedBytes, countStyle: .file))
    }

    /// The previews of the WE assets in use: the pre-warm keeps them complete.
    nonisolated static func expiryProtected() -> [URL] {
        EditorPreviewHelper.cache().map { [$0.directory] } ?? []
    }

    // MARK: Size and Clear Caches

    /// The bytes OWE's caches and its Metal shader cache take. Off the main thread.
    nonisolated static func totalSize() async -> Int64 {
        await Task.detached(priority: .utility) {
            let own = CacheSweeper(folders: CacheFolder.current).sizes().values.reduce(0, +)
            return own + (MetalShaderCache.current?.allocatedSize() ?? 0)
        }.value
    }

    struct ClearResult: Equatable {
        var removed: CacheSweeper.Result
        /// The Metal shader cache goes at the next launch.
        var metalCacheResetRequested: Bool
    }

    /// Clear Caches. Off the main thread.
    nonisolated static func clearAll() async -> ClearResult {
        let protected = await MainActor.run { clearProtected() }
        return await Task.detached(priority: .userInitiated) {
            clear(folders: CacheFolder.current, metal: MetalShaderCache.current, protected: protected)
        }.value
    }

    nonisolated static func clear(folders: [CacheFolder], metal: MetalShaderCache?, protected: [URL],
                                  leases: CacheLeases = .current) -> ClearResult {
        let removed = CacheSweeper(folders: folders, leases: leases, protected: protected).clear()
        var requested = false
        if let metal {
            do {
                try metal.requestReset()
                requested = true
            } catch {
                OWELog.error(.app, "Caches: can't ask for the Metal shader cache to be cleared: \(error)")
            }
        }
        OWELog.info(.app, "Clear Caches: removed \(removed.removedFiles) entries, "
                    + ByteCountFormatter.string(fromByteCount: removed.removedBytes, countStyle: .file)
                    + (requested ? "; the Metal shader cache goes at the next launch" : ""))
        return ClearResult(removed: removed, metalCacheResetRequested: requested)
    }

    /// The editor's previews while the Wallpaper Editor runs.
    static func clearProtected() -> [URL] {
        let editor = AppBundleLayout.editorIdentifier(for: AppStorageLocation.realBundleIdentifier)
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: editor).isEmpty else { return [] }
        return CacheFolder.current.filter { $0.id == .editorPreviews }.map(\.root)
    }
}
