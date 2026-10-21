import Foundation

/// WE's shader snippets (Replace Shader's `shader_vert_passthrough`, …), which WE's editor reads
/// from its install (`ui/dist/monaco/snippets/<name>.js`, `codeeditor`'s `y()`). Nothing of them
/// ships with the app: the assets folder's `snippets` copy, or the install beside the assets.
enum EditorShaderSnippets {
    static let installFolder = "ui/dist/monaco/snippets"
    static let cacheFolder = "snippets"

    /// The snippet `name` (a file name without `.js`); nil when the user's WE copy has none.
    static func snippet(named name: String, assets: URL? = WallpaperEngineAssets.directory,
                        fileManager: FileManager = .default) -> String? {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), let assets else { return nil }
        let candidates = [assets.appending(path: "\(cacheFolder)/\(name).js"),
                          assets.deletingLastPathComponent().appending(path: "\(installFolder)/\(name).js")]
        // A WE copy without the editor's UI has no snippets: the menu item is disabled.
        guard let file = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
        do {
            return try String(contentsOf: file, encoding: .utf8)
        } catch {
            OWELog.error(.ui, "Can't read Wallpaper Engine's snippet \(file.path): \(error)")
            return nil
        }
    }
}
