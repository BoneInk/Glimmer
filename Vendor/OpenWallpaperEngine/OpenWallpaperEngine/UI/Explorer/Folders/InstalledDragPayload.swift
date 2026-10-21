import Foundation

/// What a drag inside the Installed grid carries, as text: wallpapers (their
/// `FavoritesStore.key(for:)` keys) or a folder, each under a header line no other text has.
enum InstalledDragPayload: Equatable {
    case wallpapers([String])
    case folder(UUID)

    private static let wallpapersHeader = "open-wallpaper-engine/installed-wallpapers"
    private static let folderHeader = "open-wallpaper-engine/installed-folder"

    var text: String {
        switch self {
        case .wallpapers(let keys): return ([Self.wallpapersHeader] + keys).joined(separator: "\n")
        case .folder(let id): return Self.folderHeader + "\n" + id.uuidString
        }
    }

    /// The payload a dropped text carries; nil for any other text.
    init?(text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let header = lines.first else { return nil }
        switch header {
        case Self.wallpapersHeader where lines.count > 1:
            self = .wallpapers(Array(lines.dropFirst()))
        case Self.folderHeader where lines.count == 2:
            guard let id = UUID(uuidString: lines[1]) else { return nil }
            self = .folder(id)
        default:
            return nil
        }
    }
}

extension InstalledLibraryModel {
    /// Whether dropping `payload` in `destination` (the top level for nil) moves anything: the
    /// destination is there, and a folder never goes into itself or one of its subfolders.
    func canDrop(_ payload: InstalledDragPayload, into destination: UUID?) -> Bool {
        let tree = folders.tree
        if let destination, tree.folder(destination) == nil { return false }
        switch payload {
        case .wallpapers(let keys):
            return !keys.isEmpty
        case .folder(let id):
            guard tree.folder(id) != nil else { return false }
            guard let destination else { return true }
            return !tree.path(to: destination).contains(where: { $0.id == id })
        }
    }

    /// Files what `texts` (a drop's items) carry in `destination` (the top level for nil);
    /// returns whether any of it moved, so a refused drop slides back.
    @discardableResult
    func drop(_ texts: [String], into destination: UUID?) -> Bool {
        var handled = false
        for payload in texts.compactMap(InstalledDragPayload.init(text:)) where canDrop(payload, into: destination) {
            switch payload {
            case .wallpapers(let keys):
                folders.update { $0.move(items: keys, to: destination) }
                clearSelection()
            case .folder(let id):
                move(folder: id, toFolder: destination)
            }
            handled = true
        }
        return handled
    }
}
