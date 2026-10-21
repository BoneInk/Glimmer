import Foundation

/// Imports Wallpaper Engine's Installed folders (`WallpaperEngineFolders`, from the `config.json`
/// of the Wallpaper Engine folder chosen for the assets) into the Installed tab's folders, after
/// asking. The question is only put when the import would add something, so folders imported
/// already, or a config without folders, are never asked about. Importing merges and never
/// replaces (`InstalledFolderTree.merge`).
@MainActor
final class WallpaperEngineFoldersImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Waiting for the user's answer to add `folders` folders and file `wallpapers` wallpapers.
        case asking(folders: Int, wallpapers: Int)
        case imported(folders: Int, wallpapers: Int)
        /// WE has folders, and everything in them is here already.
        case upToDate
        /// WE's config has no folders.
        case noFolders
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Bound to the question's alert.
    @Published var isAsking = false
    /// WE's `config.json`, from the last `refreshSource()`.
    @Published private(set) var configURL: URL?

    private var pending: [InstalledFolder] = []
    private let store: InstalledFolderStore
    private let findConfig: () -> URL?
    private let localKeys: () -> [String: String]
    private let read: @Sendable (URL) throws -> Data

    init(store: InstalledFolderStore, findConfig: @escaping () -> URL?, localKeys: @escaping () -> [String: String],
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.store = store
        self.findConfig = findConfig
        self.localKeys = localKeys
        self.read = read
        refreshSource()
    }

    /// The app's own wiring: the Installed tab's folders and wallpapers, and the chosen folder.
    convenience init(assets: WallpaperEngineAssetsService, library: InstalledLibraryModel) {
        self.init(store: library.folders,
                  findConfig: { [weak assets] in WallpaperEngineFolders.configURL(chosenFolder: assets?.status.chosenFolder) },
                  localKeys: { [weak library] in WallpaperEngineFolders.localKeys(of: library?.allWallpapers ?? []) })
    }

    var isSourceAvailable: Bool { configURL != nil }

    var isChecking: Bool { phase == .checking }

    /// Looks again for WE's config, after a folder was chosen.
    func refreshSource() {
        configURL = findConfig()
    }

    /// Reads WE's folders; puts the question only when importing them adds something.
    func check() async {
        refreshSource()
        guard let configURL, phase != .checking, !isAsking else { return }
        phase = .checking
        let read = self.read
        do {
            let data = try await Task.detached(priority: .userInitiated) { try read(configURL) }.value
            let folders = WallpaperEngineFolders.importable(try WallpaperEngineFolders.folders(inConfig: data),
                                                            localKeys: localKeys())
            guard !folders.isEmpty else {
                phase = .noFolders
                return
            }
            var preview = store.tree
            let summary = preview.merge(folders)
            if summary.isEmpty {
                phase = .upToDate
            } else {
                pending = folders
                phase = .asking(folders: summary.folders, wallpapers: summary.wallpapers)
                isAsking = true
            }
        } catch {
            OWELog.error(.library, "Wallpaper Engine's folders didn't load from \(configURL.path): \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user said yes: merges WE's folders into the ones here.
    func importPending() {
        let summary = store.merge(pending)
        OWELog.info(.library, "Imported \(summary.folders) Wallpaper Engine folders and filed \(summary.wallpapers) wallpapers")
        pending = []
        isAsking = false
        phase = .imported(folders: summary.folders, wallpapers: summary.wallpapers)
    }

    /// The user said no; nothing changes, and checking again asks again.
    func decline() {
        pending = []
        isAsking = false
        phase = .idle
    }
}
