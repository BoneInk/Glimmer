import Foundation
import OWEEditor
import OWESceneEditing

/// What Add Layer › Model and Add Layer › Preset offer: the 3D models the scene can draw and WE's
/// presets that add other layers than particle systems.
extension EditorWallpaperResources {
    /// The wallpaper's `.mdl` files (its package, else its folder), then WE's, by scene path. WE's
    /// editor-only meshes (`models/editor/…`, its camera gizmo) aren't offered.
    func modelChoices() -> [EditorModelChoice] {
        var own: [String] = (package?.fileList ?? []).filter(Self.isModel)
        own += Self.files(under: wallpaper.wallpaperDirectory).filter(Self.isModel)
        var seen = Set<String>()
        var choices: [EditorModelChoice] = own.sorted().compactMap { path in
            seen.insert(path.lowercased()).inserted ? EditorModelChoice(path: path, isShared: false) : nil
        }
        for directory in WallpaperEngineAssets.searchDirectories {
            let shared = Self.files(under: directory).filter { Self.isModel($0) && !$0.lowercased().hasPrefix("models/editor/") }
            for path in shared.sorted() where seen.insert(path.lowercased()).inserted {
                choices.append(EditorModelChoice(path: path, isShared: true))
            }
        }
        return choices
    }

    /// WE's presets whose variants add other layers (`ParticlePresetCatalog.Contents.layers`),
    /// titled in WE's words; empty without WE's assets.
    func layerPresets(labels: WallpaperEngineLabels) -> [ParticlePreset] {
        guard let assets = WallpaperEngineAssets.directory else { return [] }
        return ParticlePresetCatalog.load(presetsDirectory: assets.appending(path: "presets", directoryHint: .isDirectory),
                                          contents: .layers, translate: { labels.translation($0) })
    }

    private static func isModel(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return lowered.hasPrefix("models/") && lowered.hasSuffix(".mdl")
    }

    /// Every regular file under `directory`'s `models` folder, by its path from `directory`.
    private static func files(under directory: URL) -> [String] {
        let models = directory.appending(path: "models", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(at: models, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { return [] }
        let root = directory.standardizedFileURL.path
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "mdl" {
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return paths
    }
}
