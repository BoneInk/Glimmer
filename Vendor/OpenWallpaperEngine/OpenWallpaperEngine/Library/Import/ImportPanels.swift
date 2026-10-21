//
//  ImportPanels.swift
//  Open Wallpaper Engine
//
//  Created by Haren on 2023/8/4.
//

import Cocoa
import UniformTypeIdentifiers

struct WPImportError: LocalizedError {
    var errorDescription: String?
    var failureReason: String?
    var helpAnchor: String?
    var recoverySuggestion: String?
    
    static let doesNotContainWallpaper  = WPImportError(errorDescription: String(localized: "No Wallpapers Inside"),
                                                       failureReason: String(localized: "The selected folders don't contain any wallpapers."),
                                                       helpAnchor: "Contents in Folder(s)",
                                                       recoverySuggestion: String(localized: "Check the selected folders and try again."))
    
    static let unkown                   = WPImportError(errorDescription: String(localized: "Unknown Error"),
                                                        failureReason: "",
                                                        helpAnchor: "",
                                                        recoverySuggestion: "")
}

extension AppDelegate {
    @objc func openImportFromFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip]
        panel.beginSheetModal(for: self.mainWindowController.window) { [weak self] response in
            if response != .OK { return }
            guard !panel.urls.isEmpty else { return }

            let sources = FolderImport.sources(in: panel.urls)
            guard !sources.isEmpty else {
                DispatchQueue.main.async {
                    self?.contentViewModel.presentation.alertImportModal(which: .doesNotContainWallpaper)
                }
                return
            }

            DispatchQueue.main.async {
                FolderImport.importWallpapers(sources, into: FileManager.default.wallpapersDirectory)
            }
        }
    }

    @objc func openImportVideoPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        panel.beginSheetModal(for: self.mainWindowController.window) { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.wallpaperViewModel.importVideoWallpaper(from: url)
            }
        }
    }
}
