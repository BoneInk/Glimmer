import Foundation

/// Which wallpapers the Installed tab lists where, as Wallpaper Engine's Installed tab does: in a
/// folder, the wallpapers filed in it; at the top level, the wallpapers filed in no folder. The
/// search and filters then apply to that list only, so a search at the top level doesn't find a
/// wallpaper inside a folder (WE's `sortWallpapers` starts from the folder's items, or from the
/// wallpapers outside every folder, before it filters). Folder tiles aren't searched or filtered.
enum InstalledFolderScope {
    /// The wallpapers `folder` (the top level for nil) shows, in their order.
    static func wallpapers(_ wallpapers: [WEWallpaper], in folder: UUID?, tree: InstalledFolderTree,
                           key: (WEWallpaper) -> String = FavoritesStore.key(for:)) -> [WEWallpaper] {
        if let folder {
            let items = tree.folder(folder)?.items ?? []
            return wallpapers.filter { items.contains(key($0)) }
        }
        let filed = tree.filedKeys
        guard !filed.isEmpty else { return wallpapers }
        return wallpapers.filter { !filed.contains(key($0)) }
    }

    /// How many of `installedKeys` a folder holds, its subfolders' included: the count its tile shows.
    static func wallpaperCount(of folder: InstalledFolder, installedKeys: Set<String>) -> Int {
        InstalledFolderTree(folders: [folder]).filedKeys.intersection(installedKeys).count
    }
}
