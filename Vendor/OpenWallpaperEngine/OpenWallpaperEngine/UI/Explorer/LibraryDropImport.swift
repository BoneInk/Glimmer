import SwiftUI
import UniformTypeIdentifiers

/// Files dropped on the Installed tab: videos become video wallpapers, wallpaper folders and zips
/// are copied into the library off the main thread. What wasn't imported is shown in one alert.
@MainActor
struct LibraryDropImport: DropDelegate {
    let presentation: ContentPresentation

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [UTType.fileURL])
        guard !providers.isEmpty else {
            presentation.alertImportModal(which: .unkown)
            return false
        }
        Task { @MainActor [presentation] in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            Self.importDropped(urls, droppedCount: providers.count, presentation: presentation)
        }
        return true
    }

    /// The file URL a dropped item carries; nil (logged) when it can't be read.
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    OWELog.error(.importer, "Can't read a dropped item's file URL: \(String(describing: error))")
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: url)
            }
        }
    }

    private static func importDropped(_ urls: [URL], droppedCount: Int, presentation: ContentPresentation) {
        guard !urls.isEmpty else { return presentation.alertImportModal(which: .unkown) }
        for video in DroppedFileImport.videos(in: urls) {
            AppDelegate.shared.wallpaperViewModel.importVideoWallpaper(from: video)
        }
        let library = FileManager.default.wallpapersDirectory
        Task { @MainActor in
            let problems = await Task.detached(priority: .userInitiated) {
                DroppedFileImport.importWallpapers(urls, into: library)
            }.value
            if let error = DroppedFileImport.error(for: problems) {
                presentation.alertImportModal(which: error)
            } else if urls.count < droppedCount {
                presentation.alertImportModal(which: .unkown)
            }
        }
    }
}
