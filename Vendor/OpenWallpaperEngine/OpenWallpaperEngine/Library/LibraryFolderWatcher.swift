import Foundation

/// Watches the library folders (`LibraryFolders`) and calls `onChange` once per burst of
/// wallpapers added, removed or renamed in any of them, so the Installed tab lists them without a
/// manual refresh. A folder that can't be opened (an unmounted volume) is logged and not watched
/// until the folders are set again.
@MainActor
final class LibraryFolderWatcher {
    var onChange: @MainActor () -> Void = {}
    private var watchers: [URL: DirectoryChangeWatcher] = [:]

    /// The folders being watched.
    var watchedFolders: Set<URL> { Set(watchers.keys) }

    /// Watches exactly `folders`: stops watching removed ones and starts on new ones.
    func watch(_ folders: [URL]) {
        let wanted = Set(folders.map(\.standardizedFileURL))
        for (folder, watcher) in watchers where !wanted.contains(folder) {
            watcher.stop()
            watchers.removeValue(forKey: folder)
        }
        for folder in wanted where watchers[folder] == nil {
            let watcher = DirectoryChangeWatcher(directory: folder, createsMissingDirectory: false) { [weak self] in
                self?.onChange()
            }
            if watcher.start() { watchers[folder] = watcher }
        }
    }

    func stop() {
        watch([])
    }
}
