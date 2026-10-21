import Foundation
import Photos

/// The Mac's Photos library through PhotoKit.
struct PhotoKitLibrary: LivePhotoLibrary {
    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func albumIdentifier(named name: String) async throws -> String? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
            .firstObject?.localIdentifier
    }

    func save(_ request: LivePhotoAssetRequest) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            for resource in request.resources {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                creation.addResource(with: resource.type, fileURL: resource.url, options: options)
            }
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            let assets = [placeholder] as NSArray
            if let identifier = request.albumIdentifier,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject {
                PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
            } else {
                PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: request.albumName).addAssets(assets)
            }
        }
    }
}
