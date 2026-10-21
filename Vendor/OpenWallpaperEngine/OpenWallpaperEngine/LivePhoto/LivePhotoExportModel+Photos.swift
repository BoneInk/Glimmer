import AppKit
import Photos

/// "Also Save to Photos Album" (`LivePhotoAlbumSync`): asks for Photos access the first time it is
/// turned on, turns itself back off when access is refused, and saves each export into the album
/// without failing the export when Photos can't take it.
extension LivePhotoExportModel {
    /// The Privacy & Security › Photos pane; opened, never changed.
    static let photosPrivacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    /// Turns the Photos album on (asking for access when it was never asked) or off.
    func setSavesToPhotos(_ on: Bool) {
        photosAccessDenied = false
        guard on else {
            savesToPhotos = false
            return
        }
        let status = photos.authorizationStatus()
        if LivePhotoAlbumSync.isAuthorized(status) {
            savesToPhotos = true
            return
        }
        guard status == .notDetermined else {
            denyPhotos()
            return
        }
        let photos = photos
        Task { [weak self] in
            let answer = await photos.requestAuthorization()
            guard let self else { return }
            if LivePhotoAlbumSync.isAuthorized(answer) {
                self.savesToPhotos = true
            } else {
                self.denyPhotos()
            }
        }
    }

    func openPhotosPrivacySettings() {
        NSWorkspace.shared.open(Self.photosPrivacySettings)
    }

    private func denyPhotos() {
        savesToPhotos = false
        photosAccessDenied = true
    }

    /// Saves `files` into `album` off the main thread; a failure is a notice, not an error.
    func saveToPhotos(_ files: LivePhotoHelper.Files, album: String) async {
        let photos = photos
        do {
            let name = try await Task.detached(priority: .userInitiated) {
                try await LivePhotoAlbumSync.save(still: files.still, movie: files.movie, albumName: album, library: photos)
            }.value
            photosNotice = String(localized: "Saved to the “\(name)” album in Photos.")
        } catch {
            OWELog.error(.app, "Live Photo: saving to Photos failed: \(error)")
            photosNotice = String(localized: "The Live Photo was exported but couldn't be saved to Photos: \(error.localizedDescription)")
        }
    }
}
