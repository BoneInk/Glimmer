import Foundation

/// The Details panel's Font and Size of a text layer (`_owe_text_<id>_font`, `_owe_text_<id>_size`).
/// Until the user changes them they show the layer's own font and point size, which are never
/// stored: a stored copy would pin the layer to them, over the Wallpaper Editor's Font and Size.
enum SceneTextLayerSettings {
    /// Whether `key` is a text layer's Font or Size setting.
    static func isLayerSetting(_ key: String) -> Bool {
        key.hasPrefix("_owe_text_") && (key.hasSuffix("_font") || key.hasSuffix("_size"))
    }

    /// The scene's text layers' own fonts and point sizes, under their settings' keys. A
    /// user-bound point size has none: it follows its property, and a value would pin it.
    static func layerValues(in scene: WEScene) -> [String: String] {
        var values: [String: String] = [:]
        for (index, object) in scene.objects.enumerated() where object.textValue != nil {
            let prefix = "_owe_text_\(SceneObjectIdentity.id(of: object, at: index))_"
            if let font = object.font { values[prefix + "font"] = font }
            if object.values[.pointsize]?.userPropertyName == nil, let pointSize = object.pointsize {
                values[prefix + "size"] = String(pointSize)
            }
        }
        return values
    }

    /// `stored` without the Font and Size values that equal a layer's own in any of `layerValues`.
    /// Earlier versions stored the values the settings start at; such a value changes nothing
    /// while the layer keeps it, and overrides the layer once the Wallpaper Editor changes it.
    static func removingLayerValues(from stored: [String: String],
                                    matching layerValues: [[String: String]]) -> [String: String] {
        stored.filter { key, value in
            guard isLayerSetting(key) else { return true }
            return !layerValues.contains { values in values[key].map { matches(value, $0, key: key) } ?? false }
        }
    }

    /// Sizes compare as numbers ("20" is "20.0"), fonts as text.
    private static func matches(_ stored: String, _ layer: String, key: String) -> Bool {
        if key.hasSuffix("_size"), let storedSize = Double(stored), let layerSize = Double(layer) {
            return storedSize == layerSize
        }
        return stored == layer
    }
}
