import Foundation

/// The app's caches, in the order Settings and `caches_get` list them.
extension CacheFolder {
    /// OWE's caches for the store `location` and the texture blobs in `textureRoot`
    /// (`TexturePreparation.root`, in the wallpaper storage folder). The legacy video texture
    /// folder, written by every copy before it moved into `Open Wallpaper Engine`, is the user's
    /// copy's only.
    static func ownCaches(location: AppStorageLocation, textureRoot: URL, userCaches: URL) -> [CacheFolder] {
        let caches = location.cachesDirectory.appending(path: "Open Wallpaper Engine", directoryHint: .isDirectory)
        var folders = [
            CacheFolder(id: .textures, root: textureRoot, expires: true),
            CacheFolder(id: .loadingSnapshots, root: SceneLoadingSnapshotStore.root(in: location.cachesDirectory), expires: true),
            CacheFolder(id: .editorPreviews, root: caches.appending(path: "EditorPreviews", directoryHint: .isDirectory), expires: true),
            CacheFolder(id: .videoTextures, root: EmbeddedVideoFiles.folder(in: location.cachesDirectory), expires: true),
            CacheFolder(id: .repairedVideos, root: RepairedVideoCache.root(in: location.cachesDirectory), expires: true),
            CacheFolder(id: .displayPictures, root: caches.appending(path: "DisplayPictures", directoryHint: .isDirectory), expires: false),
            CacheFolder(id: .shaderVariants, root: location.appCachesDirectory.appending(path: "shader-variants", directoryHint: .isDirectory),
                        expires: false),
            CacheFolder(id: .pipelineArchives, root: location.appCachesDirectory.appending(path: "pipeline-archives", directoryHint: .isDirectory),
                        expires: false),
        ]
        if !location.isIsolated {
            folders.append(CacheFolder(id: .legacyVideoTextures,
                                       root: userCaches.appending(path: "VideoTextures", directoryHint: .isDirectory), expires: true))
        }
        return folders
    }

    /// This process's caches.
    static var current: [CacheFolder] {
        ownCaches(location: .current, textureRoot: TexturePreparation.root,
                  userCaches: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }
}
