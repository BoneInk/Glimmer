import SwiftUI

/// WE's Move to: the top level when a folder is shown, then every folder by its path
/// ("Games / Retro"), leaving out the folder shown and, for a folder, itself and its subfolders.
/// Hidden when there is nowhere to move to.
struct MoveToFolderMenu: View {
    var library: InstalledLibraryModel
    /// The folder being moved; nil when wallpapers are.
    var movingFolder: UUID? = nil
    var move: (UUID?) -> Void

    private var destinations: [(folder: InstalledFolder, path: String)] {
        let tree = library.folders.tree
        let excluded: Set<UUID> = movingFolder.map { moving in
            Set(tree.allFolders().filter { entry in tree.path(to: entry.folder.id).contains { $0.id == moving } }.map(\.folder.id))
        } ?? []
        return tree.allFolders().filter { $0.folder.id != library.currentFolder?.id && !excluded.contains($0.folder.id) }
    }

    /// Whether the thing moved isn't at the top level already.
    private var canMoveToTopLevel: Bool {
        guard let movingFolder else { return library.currentFolder != nil }
        return library.folders.tree.path(to: movingFolder).count > 1
    }

    var body: some View {
        let destinations = self.destinations
        if canMoveToTopLevel || !destinations.isEmpty {
            Menu {
                if canMoveToTopLevel {
                    Button {
                        move(nil)
                    } label: {
                        Label {
                            Text("Top Level", comment: "Move to Folder menu item: takes wallpapers out of their folder, back to the Installed tab's top level")
                        } icon: {
                            Image(systemName: "house")
                        }
                    }
                    if !destinations.isEmpty { Divider() }
                }
                ForEach(destinations, id: \.folder.id) { entry in
                    Button {
                        move(entry.folder.id)
                    } label: {
                        Label {
                            Text(verbatim: entry.path)
                        } icon: {
                            Image(systemName: entry.folder.icon?.systemImage ?? "folder")
                        }
                    }
                }
            } label: {
                Label {
                    Text("Move to Folder", comment: "Context menu of the Installed tab: submenu that files wallpapers or a folder in another folder")
                } icon: {
                    Image(systemName: "folder.badge.plus")
                }
            }
        }
    }
}
