import Foundation

enum WebWallpaperDirectoryMode: String, Codable, Hashable, Sendable { case ondemand, fetchall }

/// Native-only manifest. Never serialize `url` or `rootURL` into page JavaScript.
struct WebWallpaperGrantedAsset: Codable, Hashable, Sendable {
    let token: String
    let url: URL
    let name: String
    let contentIdentity: String
    var virtualPath: String { "__gw_assets__/\(token)/\(name)" }
}

struct WebWallpaperGrantedDirectory: Codable, Hashable, Sendable {
    let propertyKey: String
    let mode: WebWallpaperDirectoryMode
    let assets: [WebWallpaperGrantedAsset]
    let revision: String
    let virtualPath: String
}

struct WebWallpaperResourceManifest: Codable, Hashable, Sendable {
    let itemID: UUID
    let rootURL: URL
    /// Includes directory assets too, so a renderer can validate one exact map.
    let assets: [WebWallpaperGrantedAsset]
    let directories: [WebWallpaperGrantedDirectory]
}

enum AuthorPropertyAssetKind: String, Codable, Hashable, Sendable { case file, directory }

struct AuthorPropertyAssetGrant: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let itemID: UUID
    let propertyKey: String
    let kind: AuthorPropertyAssetKind
    let value: GWJSONValue
    let revision: String
    let assets: [WebWallpaperGrantedAsset]
    let directoryMode: WebWallpaperDirectoryMode?
    var assetCount: Int { assets.count }
}

struct AuthorPropertyAssetCheckpoint: Sendable {
    let itemID: UUID
    let propertyKey: String
    let record: AuthorPropertyAssetRecord?
}

struct AuthorPropertyAssetRecord: Codable, Sendable {
    let grant: AuthorPropertyAssetGrant
    let bookmark: Data
    let contentRevision: String
    /// Native relative names only, never serialized to the Web page.
    let sourceIdentity: String?
    let relativeTokens: [String: String]?
}

struct AuthorPropertyAssetError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

enum AuthorPropertyResourceOperation: Sendable {
    case select(URL), clear, refresh, reset, retry
}

struct AuthorPropertyResourceRequest: Sendable {
    let itemID: UUID
    let project: AuthorPropertyProject
    let definition: AuthorPropertyDefinition
    let operation: AuthorPropertyResourceOperation
}

struct AuthorPropertyResourceFailure: LocalizedError, Sendable {
    let persisted: Bool
    let message: String
    init(persisted: Bool, message: String) { self.persisted = persisted; self.message = message }
    var errorDescription: String? { message }
}

@MainActor struct AuthorPropertyResourceActions {
    let perform: @MainActor (AuthorPropertyResourceRequest) async throws -> Void
    init(perform: @escaping @MainActor (AuthorPropertyResourceRequest) async throws -> Void) {
        self.perform = perform
    }
}
