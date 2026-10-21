import Foundation
import Photos

/// A Live Photo as Photos takes it: the HEIC as the photo and the MOV as its paired video (the
/// files already carry the same content identifier), into the album named `albumName`, which is
/// created when `albumIdentifier` is nil.
struct LivePhotoAssetRequest: Equatable {
    struct Resource: Equatable {
        let type: PHAssetResourceType
        let url: URL
    }

    let resources: [Resource]
    let albumName: String
    let albumIdentifier: String?
}

/// The Photos library, as saving to an album uses it (`PhotoKitLibrary`; tests use a fake).
protocol LivePhotoLibrary {
    /// Read and write access, which an album needs.
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    /// The local identifier of the regular album named `name`, if there is one.
    func albumIdentifier(named name: String) async throws -> String?
    func save(_ request: LivePhotoAssetRequest) async throws
}

/// "Also Save to Photos Album": each export also goes into an album of the Mac's Photos library,
/// as a Live Photo, so iCloud Photos brings it to the user's iPhone and iPad. PhotoKit can't create
/// or add to iCloud Shared Albums, so this is a regular album.
enum LivePhotoAlbumSync {
    static let defaultAlbumName = "Open Wallpaper Engine"

    /// The album name typed, trimmed; the default when empty.
    static func albumName(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultAlbumName : trimmed
    }

    /// Only full access can find and create albums.
    static func isAuthorized(_ status: PHAuthorizationStatus) -> Bool { status == .authorized }

    /// The request for a still and its movie into `albumName`, an existing album when
    /// `albumIdentifier` names one.
    static func request(still: URL, movie: URL, albumName: String, albumIdentifier: String?) -> LivePhotoAssetRequest {
        LivePhotoAssetRequest(resources: [.init(type: .photo, url: still), .init(type: .pairedVideo, url: movie)],
                              albumName: albumName, albumIdentifier: albumIdentifier)
    }

    /// Saves the pair into the album named `typedName` (created when missing). Returns the album's name.
    @discardableResult
    static func save(still: URL, movie: URL, albumName typedName: String, library: LivePhotoLibrary) async throws -> String {
        let name = albumName(typedName)
        let identifier = try await library.albumIdentifier(named: name)
        try await library.save(request(still: still, movie: movie, albumName: name, albumIdentifier: identifier))
        return name
    }
}
