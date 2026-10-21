import Foundation

/// Imports Wallpaper Engine's favourites (the Steam account's favourited Workshop items, see
/// `WallpaperEngineFavorites`) into My Favourites, after asking. It needs a Steam Web API key and a
/// SteamID64 found in Steam's files; without them there is no source and nothing is offered.
/// Steam is asked first, and the question is only put when it returned favourites that aren't
/// favourites here yet, so an account with none, or one already imported, is never asked.
@MainActor
final class WallpaperEngineFavoritesImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Waiting for the user's answer to import `count` new favourites.
        case asking(count: Int)
        case imported(count: Int)
        /// Steam returned favourites, and every one is a favourite here already.
        case upToDate
        /// Steam returned no favourites (none, or a private list).
        case noFavorites
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Bound to the question's alert.
    @Published var isAsking = false
    /// The SteamID64 to read, from the last `refreshSource()`.
    @Published private(set) var steamID: String?

    private var pending: [String] = []
    private let store: FavoritesStore
    private let fetch: (String) async throws -> WorkshopSubscriptions.Outcome
    private let findSteamID: () -> String?
    private let hasAPIKey: () -> Bool

    init(store: FavoritesStore, fetch: @escaping (String) async throws -> WorkshopSubscriptions.Outcome,
         findSteamID: @escaping () -> String?, hasAPIKey: @escaping () -> Bool) {
        self.store = store
        self.fetch = fetch
        self.findSteamID = findSteamID
        self.hasAPIKey = hasAPIKey
        refreshSource()
    }

    /// The app's own wiring: its favourites, Web API key, SteamCMD account and chosen folder.
    convenience init(steamCmd: SteamCmdService, assets: WallpaperEngineAssetsService) {
        let api = WorkshopAPIService()
        self.init(store: .shared,
                  fetch: { try await api.getFavoritedItemIDs(steamID: $0) },
                  findSteamID: { [weak steamCmd, weak assets] in
                      WallpaperEngineFavorites.steamID(
                          steamCmdAccount: steamCmd?.isLoggedIn == true ? steamCmd?.steamUsername : nil,
                          steamCmdPath: steamCmd?.steamCmdPath,
                          chosenFolder: assets?.status.chosenFolder)
                  },
                  hasAPIKey: { SteamCredentials.webAPIKey().load() != nil })
    }

    /// Whether favourites can be read: a key is saved and the account is known.
    var isSourceAvailable: Bool { steamID != nil }

    var isChecking: Bool { phase == .checking }

    /// Looks again for the key and the account, after a login, a new key or a chosen folder.
    func refreshSource() {
        steamID = hasAPIKey() ? findSteamID() : nil
    }

    /// Asks Steam for the favourites; puts the question only when some are new here.
    func check() async {
        refreshSource()
        guard let steamID, phase != .checking, !isAsking else { return }
        phase = .checking
        do {
            switch try await fetch(steamID) {
            case .empty:
                phase = .noFavorites
            case .items(let ids):
                let keys = WallpaperEngineFavorites.keys(forWorkshopIDs: ids)
                pending = keys.filter { !store.contains($0) }
                if keys.isEmpty {
                    phase = .noFavorites
                } else if pending.isEmpty {
                    phase = .upToDate
                } else {
                    phase = .asking(count: pending.count)
                    isAsking = true
                }
            }
        } catch {
            OWELog.error(.workshop, "Wallpaper Engine favourites didn't load: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// The user said yes: merges the new favourites, keeping the ones already there.
    func importPending() {
        let added = store.merge(pending)
        OWELog.info(.library, "Imported \(added) Wallpaper Engine favourites")
        pending = []
        isAsking = false
        phase = .imported(count: added)
    }

    /// The user said no; nothing changes, and checking again asks again.
    func decline() {
        pending = []
        isAsking = false
        phase = .idle
    }
}
