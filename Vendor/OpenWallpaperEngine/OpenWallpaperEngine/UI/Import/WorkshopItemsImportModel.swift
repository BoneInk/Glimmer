import Foundation
import Combine

/// Imports Workshop items by list: a public collection, or the user's subscriptions. Items come
/// from Steam's Web API; the checked ones go into the SteamCMD download queue, which fetches
/// their dependencies too (`WorkshopDependencyService`).
@MainActor
final class WorkshopItemsImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// Steam answered, but with no subscriptions.
        case noSubscriptions
        case failed(String)
    }

    @Published var input = ""
    @Published private(set) var phase: Phase = .idle
    /// The collection's title, for the playlist name.
    @Published private(set) var sourceTitle: String?
    @Published var createsPlaylist = true
    @Published var playlistName = ""
    /// How many items this model queued.
    @Published private(set) var queuedCount = 0
    let checklist: ImportChecklist

    private let api: WorkshopAPIService
    private let steamCmd: SteamCmdService
    private let wallpaperViewModel: WallpaperViewModel
    private let storageDirectory: () -> URL
    private var checklistChange: AnyCancellable?

    init(api: WorkshopAPIService = WorkshopAPIService(), steamCmd: SteamCmdService,
         wallpaperViewModel: WallpaperViewModel, ratings: Set<String>,
         storageDirectory: @escaping () -> URL = { WallpaperStorage.directory }) {
        self.api = api
        self.steamCmd = steamCmd
        self.wallpaperViewModel = wallpaperViewModel
        self.storageDirectory = storageDirectory
        checklist = ImportChecklist(ratings: ratings)
        checklistChange = checklist.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var canDownload: Bool { steamCmd.steamCmdPath != nil && steamCmd.isLoggedIn }

    /// Reads the collection the user pasted.
    func loadCollection() async {
        guard let id = WorkshopCollection.collectionID(from: input) else {
            phase = .failed(WorkshopCollection.Failure.invalidInput.errorDescription ?? "")
            return
        }
        phase = .loading
        do {
            let collection = try await api.getCollection(id: id)
            sourceTitle = collection.title
            playlistName = collection.title ?? ""
            show(collection.items)
        } catch {
            OWELog.error(.workshop, "Workshop collection \(id) didn't load: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Reads the account's subscriptions (best effort; see `WorkshopSubscriptions`).
    func loadSubscriptions(steamID: String) async {
        phase = .loading
        createsPlaylist = false
        do {
            switch try await api.getSubscribedItemIDs(steamID: steamID) {
            case .empty:
                phase = .noSubscriptions
            case .items(let ids):
                show(try await api.getItemDetails(inBatches: ids))
            }
        } catch {
            OWELog.error(.workshop, "Workshop subscriptions didn't load: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    private func show(_ items: [WorkshopItem]) {
        let storage = storageDirectory()
        checklist.show(items.map { item in
            WorkshopImportCandidate(item: item, isInLibrary: Self.isInLibrary(item.id, storage: storage))
        })
        phase = .loaded
    }

    nonisolated static func isInLibrary(_ id: String, storage: URL) -> Bool {
        WEProject.exists(in: storage.appending(path: id))
    }

    /// Queues the checked items; with `createsPlaylist`, a playlist named after the collection
    /// gets the listed items already in the library now and each download as it lands.
    func downloadSelected() {
        let selection = checklist.selection
        var playlistID: UUID?
        let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if createsPlaylist, !name.isEmpty {
            let storage = storageDirectory()
            let present = checklist.inLibrary.compactMap { Self.wallpaper(at: storage.appending(path: $0.id)) }
            if wallpaperViewModel.createPlaylist(named: name, wallpapers: present) {
                playlistID = wallpaperViewModel.activePlaylist?.id
            }
        }
        for candidate in selection {
            steamCmd.downloadWorkshopItem(workshopId: candidate.id, title: candidate.title,
                                          previewURL: candidate.previewURL) { [weak wallpaperViewModel] destination in
                guard let playlistID, let destination else { return }
                // steamcmd calls back off the main thread.
                DispatchQueue.main.async {
                    guard let wallpaper = Self.wallpaper(at: destination) else { return }
                    wallpaperViewModel?.addToPlaylist(wallpaper, playlistID: playlistID)
                }
            }
        }
        queuedCount += selection.count
        checklist.selectNone()
    }

    nonisolated static func wallpaper(at folder: URL) -> WEWallpaper? {
        do {
            return WEWallpaper(using: try WEProject.read(in: folder), where: folder)
        } catch {
            OWELog.error(.importer, "Can't read the project of \(folder.lastPathComponent) for the playlist: \(error)")
            return nil
        }
    }
}
