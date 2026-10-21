import Foundation
import OWEInspectorKit

/// WE's image blend modes as its editor lists them (`WEImageBlendModes`): its 33 modes in its
/// order, under its "Native (fast)" and "Emulated (slow)" groups, with WE's own labels. Scene Edit /
/// Export's and the Wallpaper Editor's Blend Mode pickers both show these.
enum SceneBlendModeOptions {
    /// The picker's title, WE's own.
    static func title(labels: WallpaperEngineLabels) -> String {
        labels.translation("ui_editor_properties_blend_mode") ?? String(localized: "Blend Mode")
    }

    static func options(labels: WallpaperEngineLabels) -> [InspectorOption] {
        SceneEffectParameters.blendModeOptions.map { option in
            InspectorOption(title: labels.translation(option.label) ?? option.english ?? option.label,
                            value: option.value,
                            group: option.group.map { labels.translation($0) ?? groupTitle($0) })
        }
    }

    /// A blend-mode group heading without WE's translation table: its English text.
    static func groupTitle(_ key: String) -> String {
        [WEImageBlendModes.nativeGroup, WEImageBlendModes.emulatedGroup].first { $0.label == key }?.english
            ?? SceneEffectParameters.title(key)
    }
}
