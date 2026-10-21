import Foundation

/// WE's New Material (the asset browser's context menu, "Enter filename for the new material:"):
/// a material file of the project, named by the author, kept with the editor's files.
extension EditorAssetStore {
    /// The material a new one starts as: one pass of WE's `generic` shader on `util/white`,
    /// drawn as a model's material is [I: the content WE's `createAsset` writes isn't known].
    static var newMaterial: [String: Any] { [
        "passes": [[
            "blending": "normal", "cullmode": "normal", "depthtest": "enabled", "depthwrite": "enabled",
            "shader": "generic", "textures": ["util/white"],
        ]],
    ] }

    /// The name without the characters WE's dialog means to strip (`"?*|:<>.`; its pattern
    /// matches them only as one run) and path separators, at most 128 characters, trimmed.
    public static func materialFileName(_ name: String) -> String {
        let removed = name.filter { !"\"?*|:<>./\\".contains($0) }
        return String(removed.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Writes `materials/<name>.json` (`<name> 2`, … when that is taken here); returns its path.
    /// Nil when the cleaned name is empty.
    public func createMaterial(named name: String) throws -> String? {
        let base = Self.materialFileName(name)
        guard !base.isEmpty else { return nil }
        var candidate = base
        var number = 2
        while url(for: "materials/\(candidate).json") != nil {
            candidate = "\(base) \(number)"
            number += 1
        }
        let path = "materials/\(candidate).json"
        try write(try JSONSerialization.data(withJSONObject: Self.newMaterial, options: [.prettyPrinted, .sortedKeys]), to: path)
        return path
    }
}
