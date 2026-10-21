import Foundation
import OWEControlProtocol
import Photos

/// The iPhone & iPad Export mode's Save, for the control channel: the same render helper
/// (`LivePhotoHelper`), the same values the mode starts from (the wallpaper's own, as the editor
/// would copy them into its isolated store), the same motion window, the parallax position the mode
/// keeps for the wallpaper, the same Photos album and the same copy into a folder.
extension AppSystemControlService {
    var exportDefaults: SystemExportDefaults {
        let defaults = UserDefaults.app
        return SystemExportDefaults(
            device: DeviceModel.model(id: defaults.string(forKey: LivePhotoExportModel.deviceKey)),
            savesToPhotos: defaults.bool(forKey: LivePhotoExportModel.savesToPhotosKey),
            photosAlbum: LivePhotoAlbumSync.albumName(defaults.string(forKey: LivePhotoExportModel.photosAlbumKey) ?? ""),
            photosAccess: Self.accessName(PhotoKitLibrary().authorizationStatus()))
    }

    /// The scene as the renderer draws it, its saved overlay applied (`SceneDrawnSize`), which the
    /// mode's crop frames, as Scene Edit / Export hands the mode its `sceneSize`.
    func sceneSize(of wallpaper: ControlWallpaper) throws -> SIMD2<Double> {
        let item = try found(wallpaper)
        do {
            return try AndroidPackageBuilder.sceneSize(item)
        } catch {
            OWELog.error(.app, "MCP: \(item.project.title)'s scene size can't be read: \(error)")
            throw ControlError(.failed, "\"\(item.project.title)\"'s \(item.project.file) can't be read: \(error.localizedDescription)")
        }
    }

    func exportLivePhoto(_ request: SystemLivePhotoRequest) async throws -> SystemLivePhotoResult {
        let wallpaper = try found(request.wallpaper)
        guard LivePhotoExportModel.isEligible(wallpaper) else {
            throw ControlError(.unsupported, "\"\(request.wallpaper.title)\" is a \(request.wallpaper.type) wallpaper; only scenes export as Live Photos.")
        }
        guard !isExporting else {
            throw ControlError(.unavailable, "Another Live Photo export from an MCP client is rendering. Wait for it to finish, then try again.")
        }
        isExporting = true
        defer { isExporting = false }
        let properties = wallpaperValues(of: wallpaper)
        let crop = LivePhotoCrop(sceneSize: try sceneSize(of: request.wallpaper), outputPixels: request.device.pixelSize,
                                 zoom: request.zoom, center: request.center)
        var settings = LivePhotoExportSettings(device: request.device, crop: crop,
                                               clip: LivePhotoClip(start: request.clipStart ?? 0, length: request.clipLength),
                                               quality: request.quality,
                                               parallaxPosition: LivePhotoParallax.position(for: wallpaper))
        let name = wallpaper.wallpaperDirectory.lastPathComponent
        if request.clipStart == nil {
            OWELog.info(.app, "MCP: measuring \(name)'s motion for its Live Photo clip")
            let analysis = try await LivePhotoHelper.analyseMotion(wallpaper, properties: properties, settings: settings,
                                                                   progress: Self.progressLog("motion of \(name)"))
            settings.clip.setStart(LivePhotoMotion.bestStart(in: analysis, length: settings.clip.length))
        }
        OWELog.info(.app, "MCP: exporting \(name) as a Live Photo for \(request.device.name)")
        let files = try await LivePhotoHelper.export(wallpaper, properties: properties, settings: settings,
                                                     progress: Self.progressLog("Live Photo of \(name)"))
        let photos = await saveToPhotos(files, requested: request.savesToPhotos)
        var photo = files.still, movie = files.movie
        if let folder = request.outputFolder {
            defer { LivePhotoHelper.remove(files) }
            (photo, movie) = try Self.copy(files, into: folder)
        }
        OWELog.info(.app, "MCP: exported \(name) as a Live Photo")
        return SystemLivePhotoResult(photo: photo, movie: movie, isInCache: request.outputFolder == nil, crop: settings.crop,
                                     clip: settings.clip, clipIsAutomatic: request.clipStart == nil, photos: photos)
    }

    /// "Also Save to Photos Album" as the mode does it, without ever asking for access.
    private func saveToPhotos(_ files: LivePhotoHelper.Files, requested: Bool) async -> SystemLivePhotoResult.Photos {
        let defaults = exportDefaults
        guard defaults.savesToPhotos else { return .off }
        guard requested else { return .skipped }
        let library = PhotoKitLibrary()
        guard LivePhotoAlbumSync.isAuthorized(library.authorizationStatus()) else {
            return .needsAccess(album: defaults.photosAlbum, access: defaults.photosAccess)
        }
        let album = defaults.photosAlbum
        do {
            let name = try await Task.detached(priority: .userInitiated) {
                try await LivePhotoAlbumSync.save(still: files.still, movie: files.movie, albumName: album, library: library)
            }.value
            return .saved(album: name)
        } catch {
            OWELog.error(.app, "Live Photo: saving to Photos failed: \(error)")
            return .failed(album: album, reason: error.localizedDescription)
        }
    }

    /// The mode's Save into a folder: the pair copied in, replacing files of the same name.
    private static func copy(_ files: LivePhotoHelper.Files, into folder: URL) throws -> (URL, URL) {
        var copied: [URL] = []
        do {
            for source in [files.still, files.movie] {
                let destination = folder.appending(path: source.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                copied.append(destination)
            }
        } catch {
            OWELog.error(.app, "MCP: copying the Live Photo into \(folder.path) failed: \(error)")
            throw ControlError(.failed, "The Live Photo was rendered but couldn't be copied into \(folder.path(percentEncoded: false)): \(error.localizedDescription)")
        }
        return (copied[0], copied[1])
    }

    /// Logs the render's progress at each quarter, which is all a client sees of it.
    private static func progressLog(_ what: String) -> @MainActor (Double) -> Void {
        let logged = LoggedQuarter()
        return { value in
            let quarter = min(Int(value * 4), 4)
            guard quarter > logged.value else { return }
            logged.value = quarter
            OWELog.info(.app, "MCP: \(what): \(quarter * 25) %")
        }
    }

    static func accessName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .limited: return "limited"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not_determined"
        @unknown default: return "unknown"
        }
    }
}

/// The last quarter of a render's progress logged; main actor only.
@MainActor
private final class LoggedQuarter {
    var value = 0
}
