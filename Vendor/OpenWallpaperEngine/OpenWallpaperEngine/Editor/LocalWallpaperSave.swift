import Foundation
import OWESceneEditing

/// Save as New Wallpaper: a copy of the wallpaper in the library with an overlay's edits (the
/// Wallpaper Editor's draft) baked into its scene.json, its puppets as `.mdl` files, its user
/// properties in project.json, the particle editor's documents as files and, when the user made
/// one, the editor's thumbnail as its preview; the wallpaper itself isn't touched. The editor window's File menu and an MCP client's `wallpaper_editor_save_as_new`
/// both save through here.
enum LocalWallpaperSave {
    /// Saves the copy into the library; returns its folder.
    static func save(_ wallpaper: WEWallpaper, overlay: SceneEditOverlay, assetsDirectory: URL, title: String,
                     thumbnail: WallpaperThumbnail? = nil) throws -> URL {
        let source = try WallpaperEditorSource.read(wallpaper)
        var writerSource = LocalWallpaperWriter.Source(directory: wallpaper.wallpaperDirectory,
                                                       sceneFile: wallpaper.project.file,
                                                       assetsDirectory: assetsDirectory)
        if let package = source.package {
            var files: [String: Data] = [:]
            for path in package.fileList where files[path] == nil {
                if let data = package.extractFile(named: path) { files[path] = data }
            }
            writerSource.packageFiles = files
            writerSource.packageName = source.packageName
        }
        let authoring = overlay.authoring
        // The editor's puppets become `.mdl` files and the layers' references (`PuppetSceneBake`).
        let read = EditorPuppetAssets.make(for: wallpaper).readFile
        let baked = try PuppetSceneBake.bake(overlay, into: try overlay.applied(to: source.scene), readFile: read)
        // The user properties as authored in the editor go into the copy's project.json; the
        // particle editor's documents (definitions, materials) and the effects made in the editor
        // are files of the copy.
        let folder = try LocalWallpaperWriter().save(writerSource, scene: baked.scene, title: title,
                                                     into: FileManager.default.wallpapersDirectory,
                                                     editProject: { authoring?.applyProperties(to: &$0) },
                                                     files: baked.files,
                                                     additionalFiles: try overlay.editorFiles(),
                                                     thumbnail: thumbnail)
        OWELog.info(.library, "Saved \(wallpaper.project.title) with its editor edits as \(folder.path)")
        return folder
    }
}
