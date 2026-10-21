import Foundation

/// The Installed tab's folders and what is filed in them, with Wallpaper Engine's operations
/// (its Installed tab's context menu): Create Folder in the folder shown, Rename, Change Icon,
/// Change Color, Move to (a folder or Home) and Remove Folder. Pure values, for tests; the app's
/// copy is `InstalledFolderStore`.
///
/// As in WE, a wallpaper or folder is in one place only: moving it takes it out of wherever it
/// was. Removing a folder removes its subfolders too, and every wallpaper filed in them goes back
/// to the top level; no wallpaper is ever deleted.
struct InstalledFolderTree: Equatable {
    /// The top-level folders.
    var folders: [InstalledFolder] = []

    // MARK: Reading

    func folder(_ id: UUID) -> InstalledFolder? {
        Self.find(id, in: folders)
    }

    private static func find(_ id: UUID, in folders: [InstalledFolder]) -> InstalledFolder? {
        for folder in folders {
            if folder.id == id { return folder }
            if let found = find(id, in: folder.subfolders) { return found }
        }
        return nil
    }

    /// The folders from the top level down to `id`, for the breadcrumbs; empty when it isn't there.
    func path(to id: UUID) -> [InstalledFolder] {
        func search(_ folders: [InstalledFolder], _ trail: [InstalledFolder]) -> [InstalledFolder]? {
            for folder in folders {
                if folder.id == id { return trail + [folder] }
                if let found = search(folder.subfolders, trail + [folder]) { return found }
            }
            return nil
        }
        return search(folders, []) ?? []
    }

    /// The folders inside `parent` (the top level for nil).
    func subfolders(of parent: UUID?) -> [InstalledFolder] {
        guard let parent else { return folders }
        return folder(parent)?.subfolders ?? []
    }

    /// The folder `key` is filed in; nil at the top level.
    func folder(containing key: String) -> InstalledFolder? {
        func search(_ folders: [InstalledFolder]) -> InstalledFolder? {
            for folder in folders {
                if folder.items.contains(key) { return folder }
                if let found = search(folder.subfolders) { return found }
            }
            return nil
        }
        return search(folders)
    }

    /// Every key filed in some folder: the top level shows the wallpapers not in it (WE's
    /// `folderRootExclusion`).
    var filedKeys: Set<String> {
        var keys = Set<String>()
        func collect(_ folders: [InstalledFolder]) {
            for folder in folders {
                keys.formUnion(folder.items)
                collect(folder.subfolders)
            }
        }
        collect(folders)
        return keys
    }

    /// The keys filed in `id` and in its subfolders.
    func keys(inside id: UUID) -> Set<String> {
        guard let folder = folder(id) else { return [] }
        return InstalledFolderTree(folders: [folder]).filedKeys
    }

    /// Every folder with its path's titles ("Games / Retro"), depth first in title order, as WE's
    /// Move to menu lists them.
    func allFolders() -> [(folder: InstalledFolder, path: String)] {
        var result: [(folder: InstalledFolder, path: String)] = []
        func visit(_ folders: [InstalledFolder], prefix: String) {
            for folder in Self.sortedByTitle(folders) {
                let path = prefix.isEmpty ? folder.title : prefix + " / " + folder.title
                result.append((folder: folder, path: path))
                visit(folder.subfolders, prefix: path)
            }
        }
        visit(folders, prefix: "")
        return result
    }

    /// A title for a new folder in `parent` (the top level for nil) that none of its folders has,
    /// ignoring case, as Finder numbers them: `base`, else "`base` 2", "`base` 3"…
    func uniqueTitle(_ base: String, in parent: UUID?) -> String {
        let taken = Set(subfolders(of: parent).map { $0.title.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Folders in title order (WE sorts them by title with `localeCompare`).
    static func sortedByTitle(_ folders: [InstalledFolder]) -> [InstalledFolder] {
        folders.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    // MARK: Changing

    /// WE's Create Folder: a new folder in `parent` (the top level for nil). A blank title is
    /// WE's default name, which the caller passes. Returns its id; nil when `parent` is gone.
    @discardableResult
    mutating func create(title: String, in parent: UUID? = nil, id: UUID = UUID()) -> UUID? {
        let folder = InstalledFolder(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let parent else {
            folders.append(folder)
            return id
        }
        guard modify(parent, { $0.subfolders.append(folder) }) else { return nil }
        return id
    }

    /// Renames the folder; a blank title changes nothing. Returns whether it was there.
    @discardableResult
    mutating func rename(_ id: UUID, to title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return folder(id) != nil }
        return modify(id) { $0.title = trimmed }
    }

    @discardableResult
    mutating func setColor(_ color: InstalledFolderColor?, of id: UUID) -> Bool {
        modify(id) { $0.color = color }
    }

    @discardableResult
    mutating func setIcon(_ icon: InstalledFolderIcon?, of id: UUID) -> Bool {
        modify(id) { $0.icon = icon }
    }

    /// WE's Remove Folder: the folder and its subfolders go, and the wallpapers filed in them
    /// are at the top level again. Returns the removed folder.
    @discardableResult
    mutating func remove(_ id: UUID) -> InstalledFolder? {
        Self.take(id, from: &folders)
    }

    /// WE's Move to for wallpapers: out of whatever folder holds them, into `destination` (the
    /// top level for nil). Returns false, changing nothing, when `destination` is gone.
    @discardableResult
    mutating func move(items keys: some Sequence<String>, to destination: UUID?) -> Bool {
        let keys = Set(keys)
        if let destination, folder(destination) == nil { return false }
        Self.unfile(keys, in: &folders)
        if let destination {
            modify(destination) { $0.items.formUnion(keys) }
        }
        return true
    }

    /// WE's Move to for a folder: into `destination` (the top level for nil). A folder can't go
    /// into itself or one of its subfolders; that, or a folder that's gone, changes nothing and
    /// returns false.
    @discardableResult
    mutating func move(folder id: UUID, to destination: UUID?) -> Bool {
        guard folder(id) != nil else { return false }
        if let destination {
            guard folder(destination) != nil, !path(to: destination).contains(where: { $0.id == id }) else { return false }
        }
        guard let moved = Self.take(id, from: &folders) else { return false }
        if let destination {
            modify(destination) { $0.subfolders.append(moved) }
        } else {
            folders.append(moved)
        }
        return true
    }

    // MARK: Merging

    /// What `merge` added.
    struct MergeSummary: Equatable {
        var folders = 0
        var wallpapers = 0
        var isEmpty: Bool { folders == 0 && wallpapers == 0 }
    }

    /// Adds `incoming` (Wallpaper Engine's folders, or an exported settings file's) to these,
    /// never replacing anything: a folder with the same title at the same level (ignoring case)
    /// is the same folder, and takes the incoming colour and icon only when it has none; a
    /// wallpaper already filed here stays where it is, and one filed nowhere goes where
    /// `incoming` files it. Merging the same folders again adds nothing.
    @discardableResult
    mutating func merge(_ incoming: [InstalledFolder]) -> MergeSummary {
        var summary = MergeSummary()
        var filed = filedKeys
        Self.merge(incoming, into: &folders, filed: &filed, summary: &summary)
        return summary
    }

    private static func merge(_ incoming: [InstalledFolder], into folders: inout [InstalledFolder],
                              filed: inout Set<String>, summary: inout MergeSummary) {
        for source in incoming {
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let index: Int
            if let existing = folders.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
                index = existing
            } else {
                folders.append(InstalledFolder(title: title))
                index = folders.count - 1
                summary.folders += 1
            }
            if folders[index].color == nil { folders[index].color = source.color }
            if folders[index].icon == nil { folders[index].icon = source.icon }
            let new = source.items.subtracting(filed)
            folders[index].items.formUnion(new)
            filed.formUnion(new)
            summary.wallpapers += new.count
            merge(source.subfolders, into: &folders[index].subfolders, filed: &filed, summary: &summary)
        }
    }

    // MARK: Helpers

    /// Applies `change` to the folder `id`; returns whether it was there.
    @discardableResult
    private mutating func modify(_ id: UUID, _ change: (inout InstalledFolder) -> Void) -> Bool {
        Self.modify(id, in: &folders, change)
    }

    private static func modify(_ id: UUID, in folders: inout [InstalledFolder], _ change: (inout InstalledFolder) -> Void) -> Bool {
        for index in folders.indices {
            if folders[index].id == id {
                change(&folders[index])
                return true
            }
            if modify(id, in: &folders[index].subfolders, change) { return true }
        }
        return false
    }

    private static func take(_ id: UUID, from folders: inout [InstalledFolder]) -> InstalledFolder? {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            return folders.remove(at: index)
        }
        for index in folders.indices {
            if let found = take(id, from: &folders[index].subfolders) { return found }
        }
        return nil
    }

    private static func unfile(_ keys: Set<String>, in folders: inout [InstalledFolder]) {
        for index in folders.indices {
            folders[index].items.subtract(keys)
            unfile(keys, in: &folders[index].subfolders)
        }
    }
}
