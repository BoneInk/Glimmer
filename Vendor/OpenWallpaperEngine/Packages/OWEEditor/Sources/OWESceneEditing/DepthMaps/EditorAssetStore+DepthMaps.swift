import Foundation

extension EditorAssetStore {
    /// Keeps a generated depth map (an 8-bit grey PNG) with the editor's files and returns the
    /// texture path an effect's slot takes (`depth/editor_<name>`; the file is
    /// `materials/depth/editor_<name>.png`). Named by its content, as every editor file is.
    public func saveDepthMap(_ png: Data, title: String) throws -> String {
        let name = "editor_" + Self.assetName(title, data: png)
        try write(png, to: "materials/\(SceneDepthParallax.textureFolder)/\(name).png")
        return "\(SceneDepthParallax.textureFolder)/\(name)"
    }

    /// The file of a depth map texture path (`depth/editor_…`), when the store has it.
    public func depthMapURL(_ texture: String) -> URL? {
        url(for: "materials/\(texture).png")
    }
}
