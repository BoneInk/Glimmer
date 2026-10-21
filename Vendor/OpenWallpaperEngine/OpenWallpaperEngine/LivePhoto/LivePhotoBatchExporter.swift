import Foundation

/// The app's worker for a Live Photo batch (`LivePhotoBatchQueue`): an item without its own
/// settings is framed for its size (a scene's drawn size, a video's picture as it plays), its
/// clip moved to its own window with the most motion when the mode's is automatic, then rendered
/// by the same helper as a single export (`LivePhotoHelper`), copied into the chosen folder and
/// saved to the Photos album when those are on. The files stay in the export cache for AirDrop.
@MainActor
final class LivePhotoBatchExporter: LivePhotoBatchWorking {
    /// Share of an item's progress its motion analysis takes.
    static let motionShare = 0.3

    let folder: URL?
    let album: String?
    let photos: LivePhotoLibrary
    /// A save to Photos that failed, or the album the batch went to.
    var onPhotos: (String) -> Void = { _ in }

    init(folder: URL?, album: String?, photos: LivePhotoLibrary) {
        self.folder = folder
        self.album = album
        self.photos = photos
    }

    func export(_ item: LivePhotoBatchItem, name: String, progress: @escaping @MainActor (Double) -> Void) async throws -> LivePhotoHelper.Files {
        var start = 0.0
        let settings: LivePhotoExportSettings
        if let given = item.settings {
            settings = given
        } else {
            var derived = item.template.settings(sceneSize: try await Self.size(of: item.wallpaper))
            if item.template.findsMotion {
                let analysis = try await LivePhotoHelper.analyseMotion(item.wallpaper, properties: item.properties, settings: derived) {
                    progress($0 * Self.motionShare)
                }
                derived.clip.setStart(LivePhotoMotion.bestStart(in: analysis, length: derived.clip.length))
                start = Self.motionShare
            }
            settings = derived
        }
        let files = try await LivePhotoHelper.export(item.wallpaper, properties: item.properties, settings: settings, name: name) {
            progress(start + $0 * (1 - start))
        }
        do {
            if let folder { try Self.copy(files, into: folder) }
        } catch {
            LivePhotoHelper.remove(files)
            throw error
        }
        if let album { await saveToPhotos(files, album: album) }
        return files
    }

    /// The size the crop is measured in: a scene's drawn size (`SceneDrawnSize`, as the mode frames
    /// it), a video's picture as it plays.
    static func size(of wallpaper: WEWallpaper) async throws -> SIMD2<Double> {
        if ScreenSaverVideoSource.isEligible(wallpaper) {
            guard let size = await SceneEditorModes.videoSize(of: wallpaper.mediaURL) else { throw LivePhotoVideoFrames.Failure.noVideoTrack }
            return size
        }
        return try await Task.detached(priority: .userInitiated) {
            try SceneDrawnSize.of(sceneData: AndroidPackageBuilder.sceneData(wallpaper),
                                  overlay: SceneDrawnSize.savedOverlay(of: wallpaper),
                                  readAsset: SceneImageSize.reader(for: wallpaper))
        }.value
    }

    /// The pair copied into `folder` (its names are already unique there).
    static func copy(_ files: LivePhotoHelper.Files, into folder: URL) throws {
        for source in [files.still, files.movie] {
            try FileManager.default.copyItem(at: source, to: folder.appending(path: source.lastPathComponent))
        }
    }

    private func saveToPhotos(_ files: LivePhotoHelper.Files, album: String) async {
        let photos = photos
        do {
            let name = try await Task.detached(priority: .userInitiated) {
                try await LivePhotoAlbumSync.save(still: files.still, movie: files.movie, albumName: album, library: photos)
            }.value
            onPhotos(String(localized: "Saved to the “\(name)” album in Photos."))
        } catch {
            OWELog.error(.app, "Live Photo batch: saving to Photos failed: \(error)")
            onPhotos(String(localized: "The Live Photo was exported but couldn't be saved to Photos: \(error.localizedDescription)"))
        }
    }
}
