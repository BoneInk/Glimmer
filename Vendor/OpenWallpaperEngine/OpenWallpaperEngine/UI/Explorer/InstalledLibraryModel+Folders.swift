import Foundation

/// The Installed tab's folders, as Wallpaper Engine's Installed tab has them: folder tiles above
/// the wallpapers of the folder shown, breadcrumbs back to the top level, and Create Folder,
/// Rename, Change Icon, Change Color, Move to and Remove Folder.
extension InstalledLibraryModel {
    /// The folder shown, if it is still there.
    var currentFolder: InstalledFolder? {
        currentFolderID.flatMap { folders.tree.folder($0) }
    }

    /// The folder the grid shows (nil for the top level), forgetting one that was removed.
    private var shownFolderID: UUID? {
        currentFolder?.id
    }

    /// The wallpapers the folder shown holds, before search and filters.
    var scopedWallpapers: [WEWallpaper] {
        InstalledFolderScope.wallpapers(allWallpapers, in: shownFolderID, tree: folders.tree)
    }

    /// The folders from the top level down to the one shown, for the breadcrumbs.
    var folderPath: [InstalledFolder] {
        shownFolderID.map(folders.tree.path(to:)) ?? []
    }

    /// The folder tiles: the folder's subfolders, in title order, which the Name sort's direction
    /// turns around as WE's Descending does. Search and filters don't hide them, as in WE.
    var displayedFolders: [InstalledFolder] {
        let sorted = InstalledFolderTree.sortedByTitle(folders.tree.subfolders(of: shownFolderID))
        return sortingSequence == .increase ? sorted.reversed() : sorted
    }

    /// How many installed wallpapers a folder tile holds, its subfolders' included.
    func wallpaperCount(of folder: InstalledFolder) -> Int {
        InstalledFolderScope.wallpaperCount(of: folder, installedKeys: Set(allWallpapers.map(FavoritesStore.key(for:))))
    }

    /// Opens a folder, or the top level for nil.
    func open(folder id: UUID?) {
        currentFolderID = id
    }

    /// The name a new folder in the one shown gets: WE's "New Folder", numbered when a folder
    /// there already has it.
    var newFolderTitle: String {
        folders.tree.uniqueTitle(String(localized: "New Folder", comment: "Default name of a folder made in the Installed tab"),
                                 in: shownFolderID)
    }

    /// WE's Create Folder: a folder in the one shown, named `title` or `newFolderTitle`.
    @discardableResult
    func createFolder(named title: String) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? newFolderTitle : trimmed
        let parent = shownFolderID
        return folders.update { $0.create(title: name, in: parent) }
    }

    /// Create Folder from a wallpaper's menu, as Finder's New Folder with Selection: a folder
    /// named `newFolderTitle` in the one shown, with `wallpapers` moved into it, in one change.
    /// Clears the selection; returns the folder's id.
    @discardableResult
    func createFolder(moving wallpapers: [WEWallpaper]) -> UUID? {
        let name = newFolderTitle
        let parent = shownFolderID
        let keys = wallpapers.map(FavoritesStore.key(for:))
        let id = folders.update { tree -> UUID? in
            guard let id = tree.create(title: name, in: parent) else { return nil }
            tree.move(items: keys, to: id)
            return id
        }
        clearSelection()
        return id
    }

    func renameFolder(_ id: UUID, to title: String) {
        folders.update { $0.rename(id, to: title) }
    }

    func setColor(_ color: InstalledFolderColor?, ofFolder id: UUID) {
        folders.update { $0.setColor(color, of: id) }
    }

    func setIcon(_ icon: InstalledFolderIcon?, ofFolder id: UUID) {
        folders.update { $0.setIcon(icon, of: id) }
    }

    /// WE's Remove Folder: its wallpapers go back to the top level; none is deleted. Showing it
    /// (or a folder inside it) goes back to the folder that held it.
    func removeFolder(_ id: UUID) {
        let path = folderPath
        folders.update { $0.remove(id) }
        if let index = path.firstIndex(where: { $0.id == id }) {
            currentFolderID = index == 0 ? nil : path[index - 1].id
        }
    }

    /// The wallpapers a menu command or a drag acts on, as WE's multi-selection does: the
    /// selection when `wallpaper` is in it (or no wallpaper is named), else `wallpaper` alone.
    func wallpapersActedOn(from wallpaper: WEWallpaper?) -> [WEWallpaper] {
        let selected = selectedWallpaperItems()
        guard let wallpaper else { return selected }
        return selected.contains(where: { $0.wallpaperDirectory == wallpaper.wallpaperDirectory }) ? selected : [wallpaper]
    }

    /// WE's Move to: files the wallpapers in `folder` (the top level for nil), out of wherever
    /// they were, and clears the selection.
    func move(_ wallpapers: [WEWallpaper], toFolder folder: UUID?) {
        let keys = wallpapers.map(FavoritesStore.key(for:))
        guard !keys.isEmpty else { return }
        folders.update { $0.move(items: keys, to: folder) }
        clearSelection()
    }

    /// Moves a folder into another one, or to the top level; never into itself or its subfolders.
    func move(folder id: UUID, toFolder destination: UUID?) {
        folders.update { $0.move(folder: id, to: destination) }
    }
}
