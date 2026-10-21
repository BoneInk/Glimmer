import Foundation

/// Calls `onChange` on the main queue after files in a folder were added, removed, renamed or
/// replaced (an atomic save is a rename into the folder), once per burst: `debounce` after the
/// last event. A `DispatchSource` on the folder itself, so it costs nothing while nothing changes.
@MainActor
final class DirectoryChangeWatcher {
    let directory: URL
    private let debounce: TimeInterval
    private let createsMissingDirectory: Bool
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// `createsMissingDirectory` false: a missing folder (a user's folder on an unmounted volume)
    /// isn't made, and `start()` fails instead.
    init(directory: URL, debounce: TimeInterval = 0.2, createsMissingDirectory: Bool = true,
         onChange: @escaping @MainActor () -> Void) {
        self.directory = directory
        self.debounce = debounce
        self.createsMissingDirectory = createsMissingDirectory
        self.onChange = onChange
    }

    /// Starts watching, making the folder when it doesn't exist yet (unless told not to). False when
    /// it can't be opened (logged).
    @discardableResult
    func start() -> Bool {
        guard source == nil else { return true }
        if createsMissingDirectory {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                OWELog.error(.app, "Can't create \(directory.path) to watch it: \(error)")
                return false
            }
        }
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            OWELog.error(.app, "Can't watch \(directory.path): \(String(cString: strerror(errno)))")
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.schedule() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        return true
    }

    /// Stops watching and closes the folder; the owner calls it before letting go.
    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pending = nil
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
