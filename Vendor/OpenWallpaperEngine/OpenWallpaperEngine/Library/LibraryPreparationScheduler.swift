import Foundation

/// Prepares a wallpaper that just arrived in the library (a Workshop download or an import) so
/// its first show is warm: the shader variant cache, the pipeline archive and the "Optimise
/// textures" blobs. The work is the app's own helper run (`HelperRunCommand`,
/// `--prepare-wallpapers`), which loads and draws the scene offscreen the way showing it would,
/// in its own process at background priority.
///
/// Each run is a `.library` job on the `PreparationPool`, so it waits while the power policy says
/// no (battery, heat); one helper runs at a time.
final class LibraryPreparationScheduler: @unchecked Sendable {
    /// Also puts the shared pool's library jobs under the power policy.
    static let shared: LibraryPreparationScheduler = {
        PowerPolicyMonitor.shared.drive(.shared)
        return LibraryPreparationScheduler()
    }()

    /// Runs the helper for `folders` and returns when it exited.
    typealias Runner = @Sendable (_ folders: [URL]) -> Void

    private let pool: PreparationPool
    private let runner: Runner
    private let lock = NSLock()
    private var queued: [URL] = []
    private var known = Set<String>()
    private var running = false

    init(pool: PreparationPool = .shared, runner: @escaping Runner = LibraryPreparationScheduler.runHelper) {
        self.pool = pool
        self.runner = runner
    }

    /// Schedules `wallpaper` (scenes only; others have nothing to prepare) once per launch.
    func prepare(_ wallpaper: WEWallpaper) {
        guard wallpaper.project.type.caseInsensitiveCompare("scene") == .orderedSame else { return }
        let folder = wallpaper.wallpaperDirectory.standardizedFileURL
        lock.lock()
        guard known.insert(folder.path).inserted else { lock.unlock(); return }
        queued.append(folder)
        lock.unlock()
        startNext()
    }

    private func startNext() {
        lock.lock()
        guard !running, !queued.isEmpty else { lock.unlock(); return }
        running = true
        let batch = queued
        queued.removeAll()
        lock.unlock()
        pool.submit(priority: .library, onCancel: { [weak self] in self?.finished() }) { [weak self] job in
            if !job.isCancelled { self?.runner(batch) }
            self?.finished()
        }
    }

    private func finished() {
        lock.lock(); running = false; lock.unlock()
        startNext()
    }

    /// Runs this app's executable with `--prepare-wallpapers`, in this process's isolated state.
    static func runHelper(_ folders: [URL]) {
        guard let process = HelperProcess.make([HelperRunCommand.prepareArgument] + folders.map { $0.path(percentEncoded: false) },
                                               qos: .background) else { return }
        process.standardOutput = FileHandle.nullDevice
        let started = Date()
        do {
            try process.run()
        } catch {
            OWELog.error(.library, "Can't start wallpaper preparation: \(error)")
            return
        }
        // Bounded: a helper that hangs is terminated (its own pid only).
        let deadline = Date().addingTimeInterval(TimeInterval(120 * folders.count + 60))
        while process.isRunning {
            if Date() > deadline { process.terminate(); break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        process.waitUntilExit()
        OWELog.info(.library, "Prepared \(folders.count) arrived wallpaper(s) in "
                    + String(format: "%.1f s", Date().timeIntervalSince(started))
                    + " (status \(process.terminationStatus))")
    }
}
