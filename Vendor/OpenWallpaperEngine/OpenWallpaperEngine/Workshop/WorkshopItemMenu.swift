import OWEInspectorKit
import SwiftUI

struct WorkshopItemMenu: View {
    let item: WorkshopItem
    @ObservedObject var viewModel: WorkshopViewModel

    var body: some View {
        if let setAs = viewModel.setAs {
            Button {
                setAs.run(.wallpaper, for: item)
            } label: {
                Label {
                    Text("Set as Wallpaper", comment: "Context menu: applies the wallpaper to the selected displays")
                } icon: {
                    Image(systemName: "checkmark.circle")
                }
            }
            .disabled(!setAs.canRun(.wallpaper, for: item))
            Button {
                setAs.run(.screenSaver, for: item)
            } label: {
                Label {
                    Text("Set as Screen Saver", comment: "Context menu: sets the wallpaper as the screen saver at once, with its default settings")
                } icon: {
                    Image(systemName: "play.rectangle")
                }
            }
            .disabled(!setAs.canRun(.screenSaver, for: item))

            Divider()
        }

        Button {
            viewModel.download(item: item)
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .disabled(!viewModel.steamCmd.isLoggedIn || viewModel.isDownloaded(item))

        Menu("Add to Playlist") {
            let playlists = AppDelegate.shared.wallpaperViewModel.playlists
            if playlists.isEmpty {
                Text("Create a playlist first")
            } else {
                ForEach(playlists) { playlist in
                    Button {
                        viewModel.downloadAndAddToPlaylist(item, playlistID: playlist.id, wallpaperViewModel: AppDelegate.shared.wallpaperViewModel)
                    } label: {
                        Label(playlist.name, systemImage: "rectangle.stack")
                    }
                }
            }
        }
        .disabled(!viewModel.steamCmd.isLoggedIn)

        Button {
            viewModel.toggleFavorite(item)
        } label: {
            Label(viewModel.isFavorite(item) ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: viewModel.isFavorite(item) ? "heart.slash" : "heart.fill")
        }

        Divider()

        Button {
            WorkshopPageLink.open(item.id)
        } label: {
            Label("Open in Workshop", systemImage: "cloud.fill")
        }
        WorkshopRelatedMenu(viewModel: viewModel, authorId: item.creatorId, presetBase: viewModel.presetBase(for: item))

        Divider()

        Button {
            WorkshopPageLink.open(item.id)
        } label: {
            Label("Report…", systemImage: "exclamationmark.triangle")
        }
        .help("Opens the wallpaper's Steam Workshop page, where you can report it to Steam")
        Button {
            viewModel.blockList.block(item)
        } label: {
            Label("Block Wallpaper", systemImage: "eye.slash")
        }
        .help("Hides this wallpaper from the Workshop and Discover tabs on this Mac. Settings › Assets lists what you blocked.")
        if let author = item.creatorId {
            let name = viewModel.authorName(of: author)
            if viewModel.blockList.isAuthorBlocked(author) {
                Button {
                    viewModel.blockList.unblockAuthor(author)
                } label: {
                    Label("Unblock \(name)", systemImage: "person.crop.circle.badge.checkmark")
                }
            } else {
                Button {
                    viewModel.blockList.blockAuthor(author, name: name)
                } label: {
                    Label("Block \(name)", systemImage: "person.crop.circle.badge.xmark")
                }
                .help("Hides this author's wallpapers from the Workshop and Discover tabs on this Mac")
            }
        }
    }
}

/// WE's "Related Wallpapers" submenu: the author's other Workshop items, and the presets
/// published for the wallpaper (or, for a preset, for its base), listed in the Workshop browser.
struct WorkshopRelatedMenu: View {
    @ObservedObject var viewModel: WorkshopViewModel
    let authorId: String?
    let presetBase: WorkshopPresetBase?

    var body: some View {
        if authorId != nil || presetBase != nil {
            Menu {
                if let authorId {
                    Button {
                        viewModel.showAuthor(authorId)
                    } label: {
                        Label("Browse All by \(viewModel.authorName(of: authorId))", systemImage: "person.fill")
                    }
                }
                if let presetBase {
                    Button {
                        viewModel.showPresets(of: presetBase)
                    } label: {
                        Label("Browse Presets", systemImage: "slider.horizontal.below.square.filled.and.square")
                    }
                }
            } label: {
                Label("Related Wallpapers", systemImage: "rectangle.stack")
            }
        }
    }
}
