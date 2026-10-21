//
//  ExplorerTopBar.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

/// The Installed tab's toolbar: search, its own items, then the window's (`WindowActionsToolbar`), attached to the tab's content so they show in the
/// window toolbar only while that tab is selected.
struct ExplorerTopBar: ViewModifier {
    var viewModel: ContentViewModel

    @EnvironmentObject var globalSettingsViewModel: GlobalSettingsViewModel

    /// Opens the sheet that adds a video or image by URL.
    let onAddURL: () -> Void

    init(contentViewModel viewModel: ContentViewModel, onAddURL: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onAddURL = onAddURL
    }

    /// Picking wallpapers for an export (`AndroidBatchPicker`): only the search, refresh and
    /// sorting work. The other items stay, disabled, so the toolbar keeps its layout.
    private var isLibrary: Bool { viewModel.allowsLibraryActions }

    func body(content: Content) -> some View {
        content
            .toolbar {
                // Search first, then the tab's items, then the window's (Details last).
                ToolbarSearchField.item(text: Bindable(viewModel.library).searchText, prompt: "Search")
                if #available(macOS 26, *) {
                    ToolbarSpacer(.fixed)
                }
                addWallpaperMenu
                ToolbarItemGroup {
                    if !viewModel.library.selectedWallpapers.isEmpty {
                        Button(role: .destructive) {
                            viewModel.presentation.isBatchUnsubscribeConfirming = true
                        } label: {
                            Label("Delete Selected (\(viewModel.library.selectedWallpapers.count))", systemImage: "trash")
                        }
                        .labelStyle(.titleAndIcon)
                        .help("Unsubscribe from the selected wallpapers")
                        .disabled(!isLibrary)
                    }
                    if globalSettingsViewModel.settings.autoRefresh {
                        Button {
                            viewModel.refresh()
                        } label: {
                            Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("Refresh the wallpaper list")
                    }
                }
                ToolbarItemGroup {
                    Button {
                        if viewModel.library.sortingSequence == .decrease {
                            viewModel.library.sortingSequence = .increase
                        } else {
                            viewModel.library.sortingSequence = .decrease
                        }
                    } label: {
                        Label(viewModel.library.sortingSequence == .increase ? "Ascending" : "Descending",
                              systemImage: viewModel.library.sortingSequence == .increase ?
                              "arrowtriangle.down.fill" : "arrowtriangle.up.fill")
                    }
                    .labelStyle(.titleAndIcon)
                    .help(viewModel.library.sortingSequence == .increase
                          ? "Sorted ascending. Click to sort descending."
                          : "Sorted descending. Click to sort ascending.")
                    SortByMenu(selection: Bindable(viewModel.library).sortingBy)
                }
                WindowActionsToolbar(viewModel: viewModel, showsDetails: true, isEnabled: isLibrary)
            }
    }

    private var addWallpaperMenu: some ToolbarContent {
        ToolbarItem {
            Menu {
                Button("New Wallpaper…", systemImage: "plus.rectangle.on.rectangle") {
                    AppDelegate.shared.openNewWallpaperWizard()
                }
                Divider()
                Button("Open Wallpaper…", systemImage: "arrow.up.bin.fill") {
                    AppDelegate.shared.openImportFromFolderPanel()
                }
                Button("Add Video Wallpaper…", systemImage: "film.stack") {
                    AppDelegate.shared.openImportVideoPanel()
                }
                Button("Add Video/Image URL…", systemImage: "link", action: onAddURL)
                Divider()
                Button("Import Workshop Collection…", systemImage: "square.stack.3d.down.right") {
                    viewModel.presentation.isCollectionImportPresented = true
                }
                Button("Import from Steam Library…", systemImage: "externaldrive.badge.person.crop") {
                    viewModel.presentation.isSteamLibraryImportPresented = true
                }
            } label: {
                Label("Add Wallpaper", systemImage: "plus")
            }
            .help("Open a wallpaper, or add a video or an image")
            .disabled(!isLibrary)
        }
    }
}
