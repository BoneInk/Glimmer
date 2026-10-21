//
//  ExplorerGlobalMenu.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/15.
//

import SwiftUI

struct ExplorerGlobalMenu: SubviewOfContentView {
    
    var viewModel: ContentViewModel
    @ObservedObject var wallpaperViewModel: WallpaperViewModel
    /// Whether it lists Create Folder…; a wallpaper's menu has its own, which moves it in.
    var includesCreateFolder: Bool

    init(contentViewModel viewModel: ContentViewModel, wallpaperViewModel: WallpaperViewModel, includesCreateFolder: Bool = true) {
        self.wallpaperViewModel = wallpaperViewModel
        self.viewModel = viewModel
        self.includesCreateFolder = includesCreateFolder
    }
    
    var body: some View {
        if includesCreateFolder {
            Section {
                Button {
                    viewModel.presentation.folderNamePrompt = .create
                } label: {
                    Label {
                        Text("Create Folder…", comment: "Context menu of the Installed tab: makes a folder in the folder shown")
                    } icon: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
        }
        Section {
            Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: FileManager.default.wallpapersDirectory.path(percentEncoded: false))
            } label: {
                Label("Open All in Finder", systemImage: "folder.badge.gearshape")
            }
            Menu("View") {
                Section {
                    Picker("Icon Size", selection: Bindable(viewModel.navigation).explorerIconSize) {
                        Text("Small Icons").tag(Double(100))
                        Text("Medium Icons").tag(Double(125))
                        Text("Large Icons").tag(Double(150))
                        Text("XL Icons").tag(Double(200))
                    }
                    .pickerStyle(.inline)
                }
            }
        }
        .labelStyle(.titleAndIcon)
    }
}
