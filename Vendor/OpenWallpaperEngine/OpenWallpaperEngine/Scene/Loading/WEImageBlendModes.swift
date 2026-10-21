/// WE's blend modes, as its editor lists them for a `"type":"imageblending"` combo (`BLENDMODE`)
/// and for an image layer's blend mode.
///
/// The list and its values are the editor's (`wallpaperui.exe` 0x140160040, which fills the menu:
/// the label keys and the value strings it pairs them with), and they match the branches of
/// `ApplyBlending` in WE's `shaders/common_blending.h` (`BLENDMODE == 1` darken … `== 32` diffuse
/// light, 0 normal). The order is the editor's: Normal and Add under "Native (fast)", then the
/// emulated ones under "Emulated (slow)"; WE 2.8.0.42's editor shows the same 33, Normal first.
enum WEImageBlendModes {
    struct Mode: Equatable {
        /// WE's localisation key (`locale/ui_en-us.json`).
        let label: String
        /// The `BLENDMODE` value.
        let value: Int
        /// WE's English text for `label`, shown when WE's translation table isn't available.
        let english: String
        /// In the editor's "Native (fast)" group; the rest are "Emulated (slow)".
        let isNative: Bool
    }

    /// `ui_editor_blending_group_native`, `ui_editor_blending_group_emulated`.
    static let nativeGroup = (label: "ui_editor_blending_group_native", english: "Native (fast)")
    static let emulatedGroup = (label: "ui_editor_blending_group_emulated", english: "Emulated (slow)")

    static let all: [Mode] = {
        let native: [(String, Int, String)] = [("normal", 0, "Normal"), ("add", 31, "Add")]
        let emulated: [(String, Int, String)] = [
            ("tint", 30, "Tint"), ("darken", 1, "Darken"), ("multiply", 2, "Multiply"),
            ("color_burn", 3, "Color burn"), ("linear_burn", 4, "Linear burn"), ("darker_color", 5, "Darker color"),
            ("lighten", 6, "Lighten"), ("screen", 7, "Screen"), ("color_dodge", 8, "Color dodge"),
            ("linear_dodge", 9, "Linear dodge"), ("lighter_color", 10, "Lighter color"), ("overlay", 11, "Overlay"),
            ("soft_light", 12, "Soft light"), ("hard_light", 13, "Hard light"), ("vivid_light", 14, "Vivid light"),
            ("linear_light", 15, "Linear light"), ("pin_light", 16, "Pin light"), ("diffuse_light", 32, "Diffuse light"),
            ("hard_mix", 17, "Hard mix"), ("difference", 18, "Difference"), ("exclusion", 19, "Exclusion"),
            ("subtract", 20, "Subtract"), ("reflect", 21, "Reflect"), ("glow", 22, "Glow"), ("phoenix", 23, "Phoenix"),
            ("average", 24, "Average"), ("negation", 25, "Negation"), ("hue", 26, "Hue"),
            ("saturation", 27, "Saturation"), ("color", 28, "Color"), ("luminosity", 29, "Luminosity"),
        ]
        func mode(_ entry: (String, Int, String), native: Bool) -> Mode {
            Mode(label: "ui_editor_blending_" + entry.0, value: entry.1, english: entry.2, isNative: native)
        }
        return native.map { mode($0, native: true) } + emulated.map { mode($0, native: false) }
    }()

    static func mode(value: Int) -> Mode? { all.first { $0.value == value } }
}
