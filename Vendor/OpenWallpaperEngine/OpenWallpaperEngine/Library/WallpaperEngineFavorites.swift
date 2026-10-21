import Foundation

/// Wallpaper Engine's favourites as `FavoritesStore` keys.
///
/// Wallpaper Engine has no favourites file: its heart calls `setFavorited` with the items'
/// Workshop ids, which favourites them in the Steam account, and the Installed tab reads them back
/// with Steam's favourited-items query. `config.json` keeps only the Discover page's followed
/// searches (`general.browser.explore.favorites`), and the Steam Cloud folder of app 431960 holds
/// only `statsutility.bin`. Only Workshop items can be favourited (the context menu skips items
/// without a `workshopid`), so every favourite maps to `workshop-<id>`, the key a Workshop
/// wallpaper has here whether or not it is installed (`FavoritesStore.key(for:)`).
enum WallpaperEngineFavorites {
    /// The keys of the favourited Workshop ids, in order, without repeats or ids that aren't one.
    static func keys(forWorkshopIDs ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter(WorkshopCollection.isID).compactMap { id in
            let key = "workshop-\(id)"
            return seen.insert(key).inserted ? key : nil
        }
    }

    /// The SteamID64 whose favourites to read, without asking for anything new: the SteamCMD
    /// account's, from Steam's files next to SteamCMD, the Steam client's and the Steam folder of
    /// the chosen Wallpaper Engine install; else, for a chosen install, the account that Steam
    /// last logged in with there.
    static func steamID(steamCmdAccount: String?, steamCmdPath: String?, chosenFolder: String?,
                        home: URL = FileManager.default.homeDirectoryForCurrentUser,
                        fileManager: FileManager = .default) -> String? {
        let installRoot = chosenFolder.flatMap { WorkshopSubscriptions.steamRoot(containing: URL(fileURLWithPath: $0)) }
        var roots = WorkshopSubscriptions.steamRoots(steamCmdPath: steamCmdPath, home: home)
        if let installRoot { roots.append(installRoot) }
        if let account = steamCmdAccount, !account.isEmpty,
           let id = WorkshopSubscriptions.steamID64(forAccount: account, steamRoots: roots, fileManager: fileManager) {
            return id
        }
        guard let installRoot else { return nil }
        return WorkshopSubscriptions.mostRecentSteamID64(steamRoots: [installRoot], fileManager: fileManager)
    }
}
