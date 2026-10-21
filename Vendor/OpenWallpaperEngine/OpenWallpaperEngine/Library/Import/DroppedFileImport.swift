import Foundation

/// Files dropped on the Installed tab: wallpaper folders and zips are copied into the library as
/// Import › From Folder does (`FolderImport`), videos become video wallpapers, and everything that
/// wasn't imported is reported with why.
enum DroppedFileImport {
    /// The video files a drop imports as video wallpapers.
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// A dropped item that wasn't imported.
    enum Problem: Equatable {
        /// The library has a folder of that name already.
        case alreadyInLibrary(name: String)
        case copyFailed(name: String, reason: String)
        /// A folder or zip with no wallpaper in it.
        case noWallpaper(name: String)
        /// Neither a folder, a zip nor a video.
        case unsupported(name: String)

        var message: String {
            switch self {
            case .alreadyInLibrary(let name):
                return String(localized: "“\(name)” is already in your library.",
                              comment: "Drag-and-drop import problem; the dropped item's name")
            case .copyFailed(let name, let reason):
                return String(localized: "“\(name)” couldn't be copied: \(reason)",
                              comment: "Drag-and-drop import problem; the dropped item's name, then the system's reason")
            case .noWallpaper(let name):
                return String(localized: "“\(name)” has no wallpaper inside.",
                              comment: "Drag-and-drop import problem; the dropped folder's or zip file's name")
            case .unsupported(let name):
                return String(localized: "“\(name)” isn't a wallpaper folder, zip file or video.",
                              comment: "Drag-and-drop import problem; the dropped file's name")
            }
        }
    }

    /// The dropped videos, which the caller imports as video wallpapers.
    static func videos(in urls: [URL]) -> [URL] {
        urls.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Copies the wallpaper folders and zips among `urls` (videos left out) into `library` and
    /// returns what wasn't imported. Blocking file IO: call off the main thread.
    static func importWallpapers(_ urls: [URL], into library: URL, fileManager: FileManager = .default,
                                 prepare: @escaping @Sendable (URL) -> Void = { WallpaperPreparation.prepare(wallpaperDirectory: $0) })
    -> [Problem] {
        var problems: [Problem] = []
        var sources = FolderImport.Sources()
        for url in urls where !videoExtensions.contains(url.pathExtension.lowercased()) {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue || url.pathExtension.lowercased() == "zip" else {
                problems.append(.unsupported(name: url.lastPathComponent))
                continue
            }
            let found = FolderImport.sources(in: [url], fileManager: fileManager)
            if found.isEmpty {
                problems.append(.noWallpaper(name: url.lastPathComponent))
            }
            sources.folders += found.folders
            sources.zips += found.zips
        }
        let outcome = FolderImport.importWallpapers(sources, into: library, fileManager: fileManager, prepare: prepare)
        for skip in outcome.skipped {
            let name = skip.source.lastPathComponent
            switch skip.reason {
            case .alreadyInLibrary: problems.append(.alreadyInLibrary(name: name))
            case .copyFailed(let reason): problems.append(.copyFailed(name: name, reason: reason))
            case .noWallpaper: problems.append(.noWallpaper(name: name))
            }
        }
        return problems
    }

    /// The alert for `problems`, nil when everything was imported.
    static func error(for problems: [Problem]) -> WPImportError? {
        guard !problems.isEmpty else { return nil }
        return WPImportError(errorDescription: String(localized: "Some Items Weren't Imported",
                                                      comment: "Alert title after a drag-and-drop import"),
                             failureReason: problems.map(\.message).joined(separator: "\n"))
    }
}
