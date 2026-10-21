import Foundation

/// A Workshop preset item: another wallpaper (its base) plus a set of property values, as WE
/// 2.8 installs one (Workshop 3332091404, a preset of 3122339805;
/// `Tests/Fixtures/Library/preset-item`).
///
/// Its project.json has no `type` and no `file`. It names the base in `dependency` (the base's
/// Workshop id as a string; Steam installs the base as a separate item beside it) and carries the
/// values in `preset`, a flat `{propertyKey: value}` object keyed like the base's
/// `general.properties`, holding raw WE values: bools, numbers, "r g b" colours, text, asset
/// paths relative to the preset's own folder (`files/…`), and `null` for a value left unset (the
/// base's default stands). The folder holds only project.json, the preview and those files.
///
/// WE lists it as an ordinary tile of its base's type with its own title and preview, and plays the
/// base with the preset's values as that item's defaults: the user's own edits to the item win,
/// and Reset goes back to the preset's values. OWE plays it from the base's folder
/// (`WEWallpaper.wallpaperDirectory`) and keeps its settings, running property store and preview
/// under the preset's folder (`WEWallpaper.presetDirectory`).
enum WorkshopPresetItem {
    /// Whether project.json declares a preset item: a `preset` object and a `dependency`.
    static func isPreset(_ root: [String: Any]) -> Bool {
        guard root["preset"] is [String: Any] else { return false }
        return !dependencyIds(root).isEmpty
    }

    /// `dependency` as Workshop ids: a string or number, or a list of them.
    static func dependencyIds(_ root: [String: Any]) -> [String] {
        guard let value = root["dependency"] else { return [] }
        let values: [Any] = (value as? [Any]) ?? [value]
        return values.compactMap { item -> String? in
            let id = (item as? String) ?? (item as? NSNumber)?.stringValue
            guard let id, !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
            return id
        }
    }

    /// The `preset` object without its unset (`null`) entries.
    static func overrides(projectJSON root: [String: Any]) -> [String: Any] {
        (root["preset"] as? [String: Any] ?? [:]).filter { !($0.value is NSNull) }
    }

    /// The folder of the preset's base wallpaper, or nil when it isn't installed. `roots` are the
    /// folders that hold Workshop items by id (the library itself).
    static func baseDirectory(forPresetAt folder: URL, projectJSON root: [String: Any], roots: [URL]) -> URL? {
        let resolver = WorkshopAssetResolver(roots: roots)
        for id in dependencyIds(root) where id != folder.lastPathComponent {
            guard let base = resolver.itemDirectory(for: id),
                  let baseRoot = projectJSON(in: base), !isPreset(baseRoot) else { continue }
            return base
        }
        return nil
    }

    /// The listed wallpaper for the preset item in `folder`: its own title, preview, tags and id,
    /// with its base's type and scene file, played from the base. Without the base it stays in its
    /// own folder as a scene (the only base type seen so far), and the missing-dependency flow
    /// offers the base's download from `dependency`.
    static func wallpaper(presetAt folder: URL, projectJSON root: [String: Any], roots: [URL]) -> WEWallpaper {
        var own = root
        own["file"] = ""
        own["type"] = ""
        own.removeValue(forKey: "preset")
        var project = Self.project(from: own, folder: folder)
            ?? WEProject(file: "", title: root["title"] as? String ?? "", type: "")
        project.applyTaggedContentRating()
        let base = baseDirectory(forPresetAt: folder, projectJSON: root, roots: roots)
        if let base, let baseRoot = projectJSON(in: base),
           let baseProject = Self.project(from: baseRoot, folder: base) {
            project.type = baseProject.type
            project.file = baseProject.file
        } else {
            project.type = "scene"
            project.file = "scene.json"
        }
        var wallpaper = WEWallpaper(using: project, where: base ?? folder)
        wallpaper.presetDirectory = ContainedPath.followingFolderLink(folder)
        return wallpaper
    }

    /// The preset's values as OWE value strings, checked against the base's property definitions
    /// (`WallpaperEngineShareJSON.values`); an asset path is resolved in the preset's folder. Empty
    /// for an ordinary wallpaper or a preset whose base isn't installed.
    static func defaultValues(for wallpaper: WEWallpaper) -> [String: String] {
        guard let presetDirectory = wallpaper.presetDirectory, presetDirectory != wallpaper.wallpaperDirectory,
              let root = projectJSON(in: presetDirectory) else { return [:] }
        let overrides = overrides(projectJSON: root)
        guard !overrides.isEmpty else { return [:] }
        let definitions = WallpaperEngineShareJSON.definitions(in: wallpaper.wallpaperDirectory)
        var values = WallpaperEngineShareJSON.values(from: overrides, definitions: definitions)
        for (key, value) in values where !value.isEmpty && !valueTypes.contains(definitions[key]?.type ?? "") {
            if let file = AssetPathResolver.fileURL(value, in: presetDirectory) {
                values[key] = file.path(percentEncoded: false)
            }
        }
        return values
    }

    /// Property types whose strings are values, never asset paths.
    private static let valueTypes: Set<String> = ["bool", "slider", "combo", "color", "text", "textinput"]

    /// `folder`'s project.json; nil without one, and, after one log line, when it can't be read.
    static func projectJSON(in folder: URL) -> [String: Any]? {
        OWELog.attempt(.library, "Preset: project.json in \(folder.lastPathComponent)", quietIfMissing: true) {
            try WEProject.object(in: folder)
        } as? [String: Any]
    }

    /// `root` (a parsed project.json) as a project; nil, after one log line, when it isn't one.
    private static func project(from root: [String: Any], folder: URL) -> WEProject? {
        OWELog.attempt(.library, "Preset: project in \(folder.lastPathComponent)") {
            try JSONDecoder().decode(WEProject.self, from: JSONSerialization.data(withJSONObject: root))
        }
    }
}
