//
//  WorkshopItemInstaller.swift
//  Open Wallpaper Engine
//
//  Where steamcmd downloads to, and how a finished item gets into the Wallpaper Storage folder.
//
//  steamcmd writes an item to `<force_install_dir>/steamapps/workshop/content/431960/<id>`, along
//  with its own manifests and partial downloads. A download's install dir is a hidden staging folder
//  inside the storage folder, so the finished item reaches `<storage>/<id>` with a rename on the
//  same volume: the library never sees half an item, and no copy is left behind. The staging folder
//  is deleted after every download. An item that has to cross volumes (a preview kept from the
//  cache, or a download whose storage folder changed meanwhile) is copied into a hidden folder in
//  the storage folder first and then renamed into place.
//

import Foundation

enum WorkshopItemInstaller {
    /// steamcmd's install dir while it downloads into a storage folder. Hidden, so the library,
    /// `WallpaperStorage.setDirectory` and the dependency cleanup all skip it.
    static let stagingFolderName = ".owe-steamcmd"
    private static let incomingPrefix = ".owe-incoming-"

    enum Failure: LocalizedError {
        case notDownloaded(workshopId: String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded(let workshopId):
                return String(localized: "steamcmd finished without downloading item \(workshopId).",
                              comment: "Download error; steamcmd is a program name, %@ a Workshop ID")
            }
        }
    }

    /// The result of putting an item into the storage folder.
    enum Outcome: Equatable {
        /// The item is now at this folder.
        case installed(URL)
        /// The storage folder already had the item, which was left as it was.
        case alreadyInstalled(URL)

        var directory: URL {
            switch self {
            case .installed(let url), .alreadyInstalled(let url): return url
            }
        }

        var isNewInstall: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    /// The Workshop previews: a size-capped cache, never the library.
    static var previewCacheRoot: URL {
        AppStorageLocation.current.cachesDirectory
            .appending(path: "Open Wallpaper Engine/WorkshopPreviews", directoryHint: .isDirectory)
    }

    static func stagingDirectory(in storage: URL) -> URL {
        storage.appending(path: stagingFolderName, directoryHint: .isDirectory)
    }

    /// Where steamcmd puts an item under `installDirectory` (its `force_install_dir`).
    static func contentDirectory(inSteamCmdRoot installDirectory: URL, workshopId: String) -> URL {
        contentRoot(inSteamCmdRoot: installDirectory).appending(path: workshopId, directoryHint: .isDirectory)
    }

    /// The folder holding every item steamcmd downloaded under `installDirectory`.
    static func contentRoot(inSteamCmdRoot installDirectory: URL) -> URL {
        installDirectory.appending(path: "steamapps/workshop/content/\(WorkshopAPIService.wallpaperEngineAppId)",
                                   directoryHint: .isDirectory)
    }

    /// Moves a downloaded item folder to `<storage>/<id>`. An item the storage folder already has
    /// is kept, and the source is removed either way, so no second copy stays behind.
    static func install(itemAt source: URL, workshopId: String, into storage: URL,
                        fileManager: FileManager = .default) throws -> Outcome {
        guard fileManager.fileExists(atPath: source.path) else { throw Failure.notDownloaded(workshopId: workshopId) }
        let destination = storage.appending(path: workshopId, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: source)
            return .alreadyInstalled(destination)
        }
        if try isSameVolume(source, storage) {
            try fileManager.moveItem(at: source, to: destination)
            return .installed(destination)
        }
        // Across volumes a move is a copy and a delete; copy next to the destination, then rename.
        let incoming = storage.appending(path: incomingPrefix + workshopId + "-" + UUID().uuidString,
                                         directoryHint: .isDirectory)
        do {
            try fileManager.copyItem(at: source, to: incoming)
            try fileManager.moveItem(at: incoming, to: destination)
        } catch {
            if fileManager.fileExists(atPath: incoming.path) {
                do {
                    try fileManager.removeItem(at: incoming)
                } catch let cleanupError {
                    OWELog.error(.workshop, "Can't remove the partial copy \(incoming.path): \(cleanupError)")
                }
            }
            throw error
        }
        try fileManager.removeItem(at: source)
        return .installed(destination)
    }

    /// Deletes a steamcmd staging folder once its download is in the library or has failed.
    static func removeStaging(_ staging: URL, fileManager: FileManager = .default) {
        guard fileManager.fileExists(atPath: staging.path) else { return }
        do {
            try fileManager.removeItem(at: staging)
        } catch {
            OWELog.error(.workshop, "Can't remove the steamcmd staging folder \(staging.path): \(error)")
        }
    }

    /// Whether `directory` is an item folder in the preview cache at `cacheRoot`.
    static func isPreview(_ directory: URL, cacheRoot: URL = previewCacheRoot) -> Bool {
        let content = contentRoot(inSteamCmdRoot: cacheRoot).standardizedFileURL
        return directory.standardizedFileURL.deletingLastPathComponent() == content
    }

    private static func isSameVolume(_ first: URL, _ second: URL) throws -> Bool {
        let firstVolume = try first.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let secondVolume = try second.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let firstVolume, let secondVolume else { return false }
        return firstVolume.isEqual(secondVolume)
    }
}
