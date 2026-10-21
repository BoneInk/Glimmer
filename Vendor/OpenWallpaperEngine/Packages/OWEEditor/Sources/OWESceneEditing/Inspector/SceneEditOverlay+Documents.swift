import Foundation

/// The JSON documents the scene's own layers read that the editor changed (an image layer's
/// material, for Lighting & Reflections), kept in the overlay (`SceneEditOverlay.documents`) by
/// their path in the wallpaper. The scene loader reads them through `editorFileData`, with the particle editor's, in place
/// of the wallpaper's files; a change of one reads the scene again; Save as New Wallpaper writes
/// them into the copy.
extension SceneEditOverlay {
    /// The edited document at `path`, nil when the editor didn't change it.
    public func document(_ path: String) -> SceneJSONValue? { documents?[path] }

    /// Sets the document at `path`; nil drops the edit (the wallpaper's file again).
    public mutating func setDocument(_ path: String, to value: SceneJSONValue?) {
        var edited = documents ?? [:]
        edited[path] = value
        documents = edited.isEmpty ? nil : edited
    }

    var hasDocumentEdits: Bool { !(documents ?? [:]).isEmpty }

    /// The edited documents as the scene loader reads files, as compact JSON; `editorFileData`
    /// hands them to the loader with the editor's other files.
    func documentData() -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, document) in documents ?? [:] {
            // Values read from JSON always write back as JSON.
            if let data = try? JSONSerialization.data(withJSONObject: document.any, options: [.fragmentsAllowed]) {
                files[path] = data
            }
        }
        return files
    }

    /// The edited documents as files of a saved copy, written as WE writes its JSON (`editorFiles`).
    func documentFiles() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for (path, document) in documents ?? [:] { files[path] = try ParticleDefinition.encode(document) }
        return files
    }
}
