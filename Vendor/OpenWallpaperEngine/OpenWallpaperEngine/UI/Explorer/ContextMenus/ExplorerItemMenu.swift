//
//  ExplorerItemMenu.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/29.
//

import SwiftUI

struct ExplorerItemMenu: SubviewOfContentView {
    
    var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @ObservedObject private var favorites = FavoritesStore.shared

    var hoveredWallpaper: WEWallpaper
    
    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, current hoveredWallpaper: WEWallpaper) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
        self.hoveredWallpaper = hoveredWallpaper
    }
    
    /// The wallpaper's Workshop id; nil for a local wallpaper.
    private var workshopId: String? {
        SceneContentLoader.workshopId(of: hoveredWallpaper)
    }

    var body: some View {
        Group {
            Section {
                Button {
                    wallpaperViewModel.inspectAndApply(hoveredWallpaper)
                } label: {
                    Label {
                        Text("Set as Wallpaper", comment: "Context menu: applies the wallpaper to the selected displays")
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .disabled(!WallpaperSetAsRules.canSetWallpaper(hoveredWallpaper))
                Button {
                    // At once, with its default settings; Scene Edit / Export's Screen Saver tab customises it.
                    AppDelegate.shared.screenSaverSelection.setAsScreenSaver(hoveredWallpaper)
                } label: {
                    Label {
                        Text("Set as Screen Saver", comment: "Context menu: sets the wallpaper as the screen saver at once, with its default settings")
                    } icon: {
                        Image(systemName: "play.rectangle")
                    }
                }
                .disabled(!WallpaperSetAsRules.canSetScreenSaver(hoveredWallpaper))
                PlayInWindowMenu(wallpaper: hoveredWallpaper)
            }

            Section {
                Menu("Add to Playlist") {
                    if wallpaperViewModel.playlists.isEmpty {
                        Text("Create a playlist first")
                    } else {
                        ForEach(wallpaperViewModel.playlists) { playlist in
                            Button {
                                let selected = viewModel.library.selectedWallpaperItems()
                                let wallpapers = selected.isEmpty ? [hoveredWallpaper] : selected
                                wallpaperViewModel.addToPlaylist(wallpapers, playlistID: playlist.id)
                            } label: {
                                Label(playlist.name, systemImage: playlist.id == wallpaperViewModel.activePlaylistID ? "checkmark" : "rectangle.stack")
                            }
                        }
                    }
                }
                Button {
                    viewModel.presentation.hoveredWallpaper = hoveredWallpaper
                    viewModel.presentation.isUnsubscribeConfirming = true
                } label: {
                    Label("Unsubscribe", systemImage: "xmark")
                }
                if viewModel.library.selectedWallpapers.count > 1 {
                    Button(role: .destructive) {
                        viewModel.presentation.isBatchUnsubscribeConfirming = true
                    } label: {
                        Label("Unsubscribe Selected (\(viewModel.library.selectedWallpapers.count))", systemImage: "xmark.circle")
                    }
                }
                Button {
                    favorites.toggle(hoveredWallpaper)
                } label: {
                    Label(favorites.contains(hoveredWallpaper) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: favorites.contains(hoveredWallpaper) ? "heart.slash" : "heart.fill")
                }
                MoveToFolderMenu(library: viewModel.library) { destination in
                    viewModel.library.move(viewModel.library.wallpapersActedOn(from: hoveredWallpaper), toFolder: destination)
                }
                Button {
                    createFolderWithWallpapers()
                } label: {
                    Label {
                        Text("Create Folder", comment: "Title of the alert that names a new folder in the Installed tab, the Installed tab's button that opens it, and the command in a wallpaper's context menu that makes a folder and moves the wallpaper (or the selection it is in) into it")
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            
            Section {
                WallpaperHotKeyMenu(wallpaper: hoveredWallpaper, wallpaperViewModel: wallpaperViewModel,
                                    hotKeys: AppDelegate.shared.userHotKeys)
            }

            Section {
                Button {
                    if let id = workshopId { WorkshopPageLink.open(id) }
                } label: {
                    Label("Open in Workshop", systemImage: "cloud.fill")
                }
                .disabled(workshopId == nil)
                if let workshopId {
                    WorkshopRelatedMenu(viewModel: viewModel.workshopVM,
                                        authorId: WorkshopMetadataStore.shared.item(for: workshopId)?.creatorId,
                                        presetBase: presetBase)
                    Button {
                        WorkshopPageLink.open(workshopId)
                    } label: {
                        Label("Report…", systemImage: "exclamationmark.triangle")
                    }
                    .help("Opens the wallpaper's Steam Workshop page, where you can report it to Steam")
                }
                Button {
                    NSWorkspace.shared.selectFile(nil,
                                                  inFileViewerRootedAtPath: hoveredWallpaper.wallpaperDirectory.path(percentEncoded: false))
                } label: {
                    Label("Open in Finder", systemImage: "folder.badge.gearshape")
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }

    /// Create Folder, as Finder's New Folder with Selection: a folder in the one shown holding
    /// this wallpaper (or the selection it is in), then its name asked for as Rename does.
    private func createFolderWithWallpapers() {
        let library = viewModel.library
        guard let id = library.createFolder(moving: library.wallpapersActedOn(from: hoveredWallpaper)),
              let folder = library.folders.tree.folder(id) else { return }
        viewModel.presentation.folderNamePrompt = .rename(folder.id, folder.title)
    }

    /// The wallpaper whose Workshop presets "Browse Presets" lists: a preset item's base, else a
    /// scene or web wallpaper itself, as WE offers it.
    private var presetBase: WorkshopPresetBase? {
        if hoveredWallpaper.isWorkshopPreset {
            let baseId = hoveredWallpaper.wallpaperDirectory.lastPathComponent
            guard WorkshopCollection.isID(baseId), hoveredWallpaper.wallpaperDirectory != hoveredWallpaper.presetDirectory
            else { return nil }
            return WorkshopPresetBase(id: baseId, title: WorkshopMetadataStore.shared.item(for: baseId)?.title ?? baseId)
        }
        guard let workshopId, ["scene", "web"].contains(hoveredWallpaper.project.type.lowercased()) else { return nil }
        return WorkshopPresetBase(id: workshopId, title: hoveredWallpaper.project.displayTitle)
    }
}
