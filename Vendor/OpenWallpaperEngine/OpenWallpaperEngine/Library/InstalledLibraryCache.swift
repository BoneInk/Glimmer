import Foundation

/// The Installed library as `InstalledLibrary` lists it, re-reading a folder's project.json only
/// when its modification date changed, and remembering the facts the Installed tab filters and
/// sorts by (size on disk, customizable properties) with it.
///
/// The Installed tab used to rescan and decode every project.json several times per redraw, and
/// sorting by size walked each folder once per comparison. A pass here lists the library folder
/// and reads one modification date per wallpaper, so the view stays as fresh as before: a folder
/// that appears, disappears or has its project.json rewritten shows up on the next pass.
///
/// Main-thread only (it belongs to the Installed tab's view model); not thread-safe.
final class InstalledLibraryCache {
    private struct Entry {
        /// project.json's modification date; nil when it's missing.
        let projectModified: Date?
        /// The folder's own modification date, which moves when files are added or removed in it.
        let folderModified: Date?
        /// Nil when the folder isn't a listed wallpaper (not a wallpaper type).
        let wallpaper: WEWallpaper?
        var size: Int?
        var hasCustomizableProperties: Bool?
    }

    private var entries: [URL: Entry] = [:]
    /// Whether a pass has listed the folder: wallpapers that appear after it are arrivals.
    private var listedOnce = false
    /// Called with each wallpaper that appears after the first pass (a download or an import).
    var onArrival: (WEWallpaper) -> Void = { _ in }

    /// The listed wallpapers in `directory`, in folder order, without `dependencyIds`, then those of
    /// each of `libraryFolders` (Settings › Library Folders). In a library folder only folders with
    /// a project.json count (it may hold anything else), dependency-only items aren't a thing, and
    /// a Workshop item already listed from an earlier folder isn't listed twice. A library folder
    /// that can't be read (an unmounted volume) is logged and skipped.
    func wallpapers(in directory: URL, libraryFolders: [URL] = [], hiding dependencyIds: Set<String>) -> [WEWallpaper] {
        var seen = Set<URL>()
        var result: [WEWallpaper] = []
        var listedIds = Set<String>()
        // A linked wallpaper folder is kept by the folder it points to, which its wallpaper runs
        // from (`WEWallpaper`), so `size(of:)` finds its entry; its id is the link's name.
        for listed in Self.contents(of: directory) ?? [] {
            let folder = ContainedPath.followingFolderLink(listed)
            seen.insert(folder)
            guard !dependencyIds.contains(listed.lastPathComponent) else { continue }
            append(folder, id: listed.lastPathComponent, to: &result, listedIds: &listedIds)
        }
        for libraryFolder in libraryFolders where libraryFolder.standardizedFileURL != directory.standardizedFileURL {
            for listed in Self.contents(of: libraryFolder) ?? [] {
                let folder = ContainedPath.followingFolderLink(listed)
                seen.insert(folder)
                let id = listed.lastPathComponent
                guard !(WorkshopCollection.isID(id) && listedIds.contains(id)),
                      FileManager.default.fileExists(atPath: WEProject.url(in: folder).path(percentEncoded: false))
                else { continue }
                append(folder, id: id, to: &result, listedIds: &listedIds)
            }
        }
        entries = entries.filter { seen.contains($0.key) }
        listedOnce = true
        return result
    }

    private func append(_ folder: URL, id: String, to result: inout [WEWallpaper], listedIds: inout Set<String>) {
        let arrived = listedOnce && entries[folder] == nil
        guard let wallpaper = entry(for: folder).wallpaper else { return }
        result.append(wallpaper)
        listedIds.insert(id)
        if arrived { onArrival(wallpaper) }
    }

    /// The folder's items, or nil when it can't be listed (logged).
    private static func contents(of directory: URL) -> [URL]? {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: ContainedPath.followingFolderLink(directory), includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles)
        } catch {
            OWELog.error(.library, "Can't list the wallpaper library at \(directory.path): \(error)")
            return nil
        }
    }

    /// The wallpaper's size on disk, measured once per change of its folder or project.json.
    func size(of wallpaper: WEWallpaper) -> Int {
        let folder = wallpaper.wallpaperDirectory
        if let size = entries[folder]?.size { return size }
        let size = wallpaper.wallpaperSize
        entries[folder]?.size = size
        return size
    }

    /// Whether project.json has user properties besides the scheme colour, read once per change.
    func hasCustomizableProperties(_ wallpaper: WEWallpaper) -> Bool {
        let folder = wallpaper.wallpaperDirectory
        if let known = entries[folder]?.hasCustomizableProperties { return known }
        let value = wallpaper.hasCustomizableProperties
        entries[folder]?.hasCustomizableProperties = value
        return value
    }

    private func entry(for folder: URL) -> Entry {
        let projectModified = Self.modificationDate(of: WEProject.url(in: folder))
        let folderModified = Self.modificationDate(of: folder)
        // A preset whose base isn't installed yet is re-resolved each pass, so it plays once the base arrives.
        if let cached = entries[folder], cached.projectModified == projectModified,
           !(cached.wallpaper.map { $0.isWorkshopPreset && $0.wallpaperDirectory == $0.presetDirectory } ?? false) {
            if cached.folderModified == folderModified { return cached }
            // Files came or went: the project is the same but the size may not be.
            let refreshed = Entry(projectModified: projectModified, folderModified: folderModified,
                                  wallpaper: cached.wallpaper, size: nil,
                                  hasCustomizableProperties: cached.hasCustomizableProperties)
            entries[folder] = refreshed
            return refreshed
        }
        let entry = Entry(projectModified: projectModified, folderModified: folderModified,
                          wallpaper: InstalledLibrary.wallpaper(at: folder, hiding: []),
                          size: nil, hasCustomizableProperties: nil)
        entries[folder] = entry
        return entry
    }

    private static func modificationDate(of url: URL) -> Date? {
        // A missing file has no date, which is itself a state the entry records.
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
