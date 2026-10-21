import Foundation

/// A layer shown for one value of a combo user property: its `visible` is bound to the property
/// with a condition (`"visible": {"user": {"name": …, "condition": …}}`), so it is one of the
/// wallpaper's alternative versions, and choosing it sets the property to that value.
struct SceneLayerVersion: Equatable {
    /// The combo property's key.
    let property: String
    /// The property value that shows the layer.
    let value: String
    /// The option's label as authored (plain text, HTML or a WE localisation key); the value when
    /// no option has it.
    let label: String

    /// nil unless the object's visibility is bound, with a condition, to a combo property the
    /// project declares.
    init?(object: WESceneObject, definitions: [String: UserPropertyDefinition]) {
        guard let property = object.visibleUserProperty, let value = object.visibleCondition,
              let definition = definitions[property], definition.type == "combo" else { return nil }
        self.property = property
        self.value = value
        label = definition.options.first { $0.value == value }?.label ?? value
    }

    /// The label as the inspector shows it: the translation of a localisation key (WE's or the
    /// wallpaper's own), else the text, without its markup.
    func title(labels: WallpaperEngineLabels) -> String {
        UserPropertyHTML.plainText(labels.translation(label) ?? label)
    }
}
