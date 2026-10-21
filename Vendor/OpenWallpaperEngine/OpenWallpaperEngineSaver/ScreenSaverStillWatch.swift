import Foundation

/// The still a saver view shows (`ScreenSaverStills`): the file listed for its display in the
/// shared folder, and what tells one version of it from the next. The app replaces a still by
/// renaming a new file over it (a new hard link of the lock-screen picture, a new pick), so the
/// same name with another file is another still. Foundation only, shared by the savers and tests.
struct ScreenSaverStillChoice: Equatable {
    var url: URL
    /// The file's name, inode and modification time.
    var key: String

    /// The still listed for `display` in `folder` now; nil when none is listed or the listed file
    /// isn't there (the view then keeps what it shows rather than going black).
    static func current(in folder: URL, display: String?) -> ScreenSaverStillChoice? {
        guard let file = ScreenSaverStills.read(folder.appending(path: ScreenSaverStills.fileName))?
            .file(forDisplay: display) else { return nil }
        let url = folder.appending(path: file, directoryHint: .notDirectory)
        var info = stat()
        guard stat(url.path(percentEncoded: false), &info) == 0 else { return nil }
        let modified = info.st_mtimespec
        return ScreenSaverStillChoice(url: url, key: "\(file)|\(info.st_ino)|\(modified.tv_sec).\(modified.tv_nsec)")
    }
}

/// Tells the saver views of a process that the shared folder changed (`stills.json` or a still
/// rewritten, a pick set or cleared), so a view, System Settings' preview included, shows the
/// current still at once instead of the one it found when it was made. One `DispatchSource` on
/// the folder for the whole process; changes close together are told once. Main thread.
final class ScreenSaverFolderWatch {
    static let shared = ScreenSaverFolderWatch(folder: ScreenSaverManifest.sharedFolder(home: ScreenSaverManifest.userHome))

    /// How long after a change the views are told: the app writes a still and then lists it.
    static let settle: TimeInterval = 0.15

    let folder: URL
    private let settle: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var handlers: [ObjectIdentifier: () -> Void] = [:]
    private var pending: DispatchWorkItem?

    init(folder: URL, settle: TimeInterval = ScreenSaverFolderWatch.settle) {
        self.folder = folder
        self.settle = settle
    }

    /// Whether the folder is watched; until it is (it doesn't exist yet), views look again as
    /// they tick.
    var isWatching: Bool { source != nil }

    /// Calls `handler` on the main thread after each change, until `remove(owner)`.
    func add(_ owner: AnyObject, _ handler: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        handlers[ObjectIdentifier(owner)] = handler
        watch()
    }

    func remove(_ owner: AnyObject) {
        dispatchPrecondition(condition: .onQueue(.main))
        handlers[ObjectIdentifier(owner)] = nil
        guard handlers.isEmpty else { return }
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    /// Starts watching when there are views and the folder exists; harmless when it already does.
    func watch() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard source == nil, !handlers.isEmpty else { return }
        let descriptor = open(folder.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                               eventMask: [.write, .delete, .rename, .link], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                // The folder itself went (the plugin was turned off): watched again once it is back.
                source.cancel()
                if self.source === source { self.source = nil }
            }
            self.changed()
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.watch()
            for handler in Array(self.handlers.values) { handler() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }
}
