import Foundation

/// The effects made in the editor (`effectFiles`): their `effect.json`, materials and shaders,
/// kept in the overlay like every other edit, so they are part of the draft, of File › Save and of
/// Save as New Wallpaper. The scene loader reads them before the wallpaper's own files and WE's
/// (`editorFileData`), as it reads the particle editor's documents.
extension SceneEditOverlay {
    public var hasEffectFiles: Bool { !(effectFiles ?? [:]).isEmpty }

    /// The text of the editor's file at `path`, if the overlay has one.
    public func effectFile(_ path: String) -> String? {
        effectFiles?[path]
    }

    /// Sets (or, with nil, removes) the editor's file at `path`; an overlay without any keeps none.
    public mutating func setEffectFile(_ path: String, text: String?) {
        var files = effectFiles ?? [:]
        files[path] = text
        effectFiles = files.isEmpty ? nil : files
    }

    /// The `effect.json` files of the effects the overlay holds (`effects/<name>/effect.json`), sorted.
    public var customEffectFiles: [String] {
        CustomEffect.effectFiles(in: Array((effectFiles ?? [:]).keys))
    }

    /// Every document the editor wrote that the scene loader reads in place of a file: the
    /// particle editor's and the layers' edited documents (`documents`, as compact JSON) and the
    /// effects' files (as written).
    public func editorFileData() -> [String: Data] {
        var files = particles?.assetData() ?? [:]
        files.merge(documentData()) { _, document in document }
        for (path, text) in effectFiles ?? [:] { files[path] = Data(text.utf8) }
        return files
    }

    /// The same documents as files of a wallpaper (Save as New Wallpaper): the particle editor's
    /// and the layers' as WE writes them, the effects' files as they are.
    public func editorFiles() throws -> [String: Data] {
        var files = try particles?.assetFiles() ?? [:]
        files.merge(try documentFiles()) { _, document in document }
        for (path, text) in effectFiles ?? [:] { files[path] = Data(text.utf8) }
        return files
    }
}
