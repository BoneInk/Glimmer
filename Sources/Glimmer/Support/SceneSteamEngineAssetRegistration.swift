import Foundation

extension SceneEngineAssetResolver {
    /// The helper/broker is the only download authority. This adapter accepts its
    /// verified completion and publishes no project-controlled filesystem root.
    static func registerVerifiedSteamBundle(_ bundle: SteamEngineAssetBundle) throws {
        try production.registerVerifiedSteamBundle(bundle)
    }

    func registerVerifiedSteamBundle(_ bundle: SteamEngineAssetBundle) throws {
        let files = try bundle.files.map { file -> File in
            guard file.relativePath == "assets/" + file.logicalPath else {
                throw SceneWallpaperFailure(message: "无效的 Steam 内置资源相对路径。")
            }
            return File(logicalPath: file.logicalPath, sha256: file.sha256, sizeBytes: file.sizeBytes)
        }
        let identity = bundle.manifestIdentity
        try register(.init(schemaVersion: 1, appID: 431960,
            manifestIdentity: .init(sha256: identity.sha256, depotID: identity.depotID, manifestID: String(identity.manifestID)), files: files),
            expectedContentRoot: bundle.cacheRoot)
    }
}
