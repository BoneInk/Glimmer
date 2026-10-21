//
//  WallpaperExplorer.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct WallpaperExplorer: SubviewOfContentView {
    var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    @State private var isCreatePlaylistPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel) {
        self.viewModel = viewModel
        self.wallpaperViewModel = wallpaperViewModel
    }

    /// Picking wallpapers for an Android batch: the grid only selects.
    private var exportSelection: AndroidBatchPicker? { viewModel.androidBatchPicker }

    var body: some View {
        VStack(spacing: 8) {
            if viewModel.library.currentFolder != nil {
                InstalledFolderBreadcrumbs(viewModel: viewModel)
            }
            Group {
                if viewModel.library.displayedWallpapers.isEmpty && viewModel.library.displayedFolders.isEmpty {
                    emptyMessage
                        .font(.title)
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // The whole list in one scrolling grid, the folder shown's folders first (as in
                    // WE); tiles are made as they scroll in.
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(
                                .adaptive(
                                    minimum: viewModel.navigation.explorerIconSize,
                                    maximum: viewModel.navigation.explorerIconSize
                                ),
                                spacing: 8
                            )
                        ], alignment: .leading, spacing: 8) {
                            ForEach(viewModel.library.displayedFolders) { folder in
                                InstalledFolderTile(viewModel: viewModel, folder: folder)
                                    .transition(InstalledDropAnimation.removal(reduceMotion: reduceMotion))
                                    .libraryContextMenu(isEnabled: viewModel.allowsLibraryActions) {
                                        InstalledFolderMenu(viewModel: viewModel, folder: folder)
                                        ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel)
                                    }
                            }
                            ForEach(viewModel.library.displayedWallpapers, id: \.wallpaperDirectory) { wallpaper in
                                ExplorerItem(viewModel: viewModel, wallpaperViewModel: wallpaperViewModel, wallpaper: wallpaper)
                                    .transition(InstalledDropAnimation.removal(reduceMotion: reduceMotion))
                                    .libraryContextMenu(isEnabled: viewModel.allowsLibraryActions) {
                                        ExplorerItemMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel, current: wallpaper)
                                        ExplorerGlobalMenu(contentViewModel: viewModel, wallpaperViewModel: wallpaperViewModel,
                                                           includesCreateFolder: false)
                                    }
                            }
                        }
                        .padding(.bottom, 8)
                        // Room for the export picker's banner, which floats over the grid.
                        .padding(.top, exportSelection == nil ? 0 : AndroidBatchPickerBanner.height + 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            // An overlay, so the banner adds nothing to the column's minimum height: in the
            // stack it pushed the grid and the bar below the window's bottom edge.
            .overlay(alignment: .top) {
                if let exportSelection {
                    AndroidBatchPickerBanner(selection: exportSelection)
                }
            }

            if let exportSelection {
                AndroidBatchPickerBar(selection: exportSelection)
            } else {
                libraryActions
            }
        }
        .modifier(InstalledFolderPrompts(viewModel: viewModel))
        .sheet(isPresented: $isCreatePlaylistPresented) {
            CreatePlaylistSheet(
                wallpapers: viewModel.library.selectedWallpaperItems(),
                wallpaperViewModel: wallpaperViewModel,
                onComplete: {
                    viewModel.library.clearSelection()
                    isCreatePlaylistPresented = false
                }
            )
            .frame(width: 480, height: 360)
            .presentationBackground(.regularMaterial)
        }
    }

    /// The buttons under the grid.
    private var libraryActions: some View {
        GlassGroup {
            HStack(spacing: 8) {
                Button {
                    isCreatePlaylistPresented = true
                } label: {
                    Label("Create Playlist", systemImage: "rectangle.stack.badge.plus")
                }
                .glassButtonStyle()
                .disabled(viewModel.library.selectedWallpapers.isEmpty)
                Button {
                    viewModel.presentation.folderNamePrompt = .create
                } label: {
                    Label {
                        Text("Create Folder", comment: "Title of the alert that names a new folder in the Installed tab, the Installed tab's button that opens it, and the command in a wallpaper's context menu that makes a folder and moves the wallpaper (or the selection it is in) into it")
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                .glassButtonStyle()
                .help("Makes a folder in the folder shown, to organise your wallpapers")
                EditWallpaperButton(wallpaperViewModel: wallpaperViewModel)
            }
            .padding(.vertical, 8)
        }
    }
}

extension WallpaperExplorer {
    /// What an empty grid says: an empty folder, or a search or filters nothing matches.
    @ViewBuilder fileprivate var emptyMessage: some View {
        if viewModel.library.currentFolder != nil
            && viewModel.library.searchText.isEmpty && viewModel.library.scopedWallpapers.isEmpty {
            Text("This folder is empty. Drag wallpapers here, or use Move to Folder in their menu.",
                 comment: "Shown in an empty folder of the Installed tab")
        } else {
            Text("No wallpapers found for your search.")
        }
    }
}

private struct CreatePlaylistSheet: View {
    let wallpapers: [WEWallpaper]
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    let onComplete: () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create Playlist").font(.title2.bold())
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("\(wallpapers.count) wallpapers will be added")
                .foregroundStyle(.secondary)
            List(wallpapers) { wallpaper in
                Text(verbatim: wallpaper.project.displayTitle)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onComplete)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard wallpaperViewModel.createPlaylist(named: name, wallpapers: wallpapers) else { return }
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(.prominent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
