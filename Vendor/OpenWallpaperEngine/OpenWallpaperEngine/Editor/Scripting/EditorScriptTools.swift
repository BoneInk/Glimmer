import Foundation

/// What the Wallpaper Editor's script editor reads from the user's Wallpaper Engine copy, and its
/// Run Preview / Stop Preview on the canvas.
///
/// - Snippets: WE's editor reads its snippet scripts from its install
///   (`ui/dist/monaco/snippets/<name>.js`, `scripteditor`'s `y()`), as the shader editor's
///   (`EditorShaderSnippets`, which both read); the assets cache keeps a copy in `<cache>/snippets`
///   (`WallpaperEngineAssetsCache`). Nothing of them ships with the app; a snippet WE doesn't have
///   is the editor's own (`SceneScriptSnippet`).
/// - Modules: the runtime imports WE's `scripts/jsmodules/<name>.js` by name, case-insensitively
///   (`SceneScriptPrelude`); Import Custom Module lists the ones besides WE's base three.
enum EditorScriptTools {
    /// The modules of WE's `scripts/jsmodules` besides the base ones (WEColor, WEMath, WEVector),
    /// by file name, sorted.
    static func customModules(assets: URL? = WallpaperEngineAssets.directory, fileManager: FileManager = .default) -> [String] {
        guard let assets else { return [] }
        let folder = assets.appending(path: "scripts/jsmodules", directoryHint: .isDirectory)
        // No jsmodules folder: nothing to list (the prelude logs a missing one).
        guard fileManager.fileExists(atPath: folder.path) else { return [] }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: folder.path)
        } catch {
            OWELog.error(.ui, "Can't list \(folder.path): \(error)")
            return []
        }
        let base = Set(["wecolor", "wemath", "wevector"])
        return names.filter { ($0 as NSString).pathExtension.lowercased() == "js" }
            .map { ($0 as NSString).deletingPathExtension }
            .filter { !base.contains($0.lowercased()) }
            .sorted()
    }
}

extension SceneWallpaperInstance {
    /// Run Preview / Stop Preview: the canvas's scripts stop (every field back to its authored
    /// value, the objects scripts made gone) or start again from their beginning, as the content
    /// is applied again.
    func setScriptsRunning(_ running: Bool) {
        renderLoop.perform { $0.scripts.isSuspended = !running }
        loadContent()
    }
}
