import Foundation

/// The filters WE's "Image filter" lists, in its order (`ui/dist/scripts/scripts.js`,
/// `wpxGlobalData.lutFilterOptionFiles`): the LUT's name in `materials/lut` and its label. The
/// menu numbers them from 1 after "None" (`t + " " + label`).
enum WEImageFilters {
    struct Filter: Equatable {
        /// `materials/lut/<name>.tex`, the value `wcc_v` holds.
        let name: String
        /// English text of `ui_browse_lut_filter_<name>`.
        let english: String

        var labelKey: String { "ui_browse_lut_filter_\(name)" }
    }

    /// "None" (`ui_browse_properties_image_filter_none`), value "".
    static let noneLabel = (key: "ui_browse_properties_image_filter_none", english: "None")

    static let all: [Filter] = [
        Filter(name: "k23_b", english: "Vibrant Contrast"),
        Filter(name: "lutx32_adventure", english: "Vibrant Darkness"),
        Filter(name: "lutx32_coloration", english: "Color Boost"),
        Filter(name: "simple_film", english: "Shadow Boost"),
        Filter(name: "lutx32_bluenavy", english: "Moon Light"),
        Filter(name: "80s_post-apocalyptic_action", english: "Late Night"),
        Filter(name: "desert_4", english: "Desert"),
        Filter(name: "desperado", english: "Midday Sun"),
        Filter(name: "lutx32_dusk", english: "Sunrise"),
        Filter(name: "lutx32_honeyb", english: "Honey"),
        Filter(name: "lutx32_sandyskyd", english: "Autumn"),
        Filter(name: "lutx32_slate", english: "Sepia Modern"),
        Filter(name: "lutx32_westernf", english: "Western"),
        Filter(name: "setting_sun", english: "Sunset"),
        Filter(name: "tower", english: "Color Crush"),
        Filter(name: "lutx32_amber", english: "Amber"),
        Filter(name: "aliens_2", english: "Toxic Green"),
        Filter(name: "lutx32_daisy", english: "Daisy"),
        Filter(name: "lutx32_emeraldd", english: "Emerald"),
        Filter(name: "lutx32_ferne", english: "Overcast"),
        Filter(name: "lutx32_backsea", english: "Blueshift"),
        Filter(name: "lutx32_beach", english: "Beach"),
        Filter(name: "lutx32_studio", english: "Studio Lighting"),
        Filter(name: "sharp_wasteland", english: "Wasteland"),
        Filter(name: "gamebob_2", english: "Retro Handheld"),
    ]

    /// The menu's options, "None" first, each titled with `translate` (WE's text for a key, if any).
    static func options(translate: (String) -> String?) -> [(title: String, value: String)] {
        [(translate(noneLabel.key) ?? noneLabel.english, "")]
            + all.enumerated().map { index, filter in
                ("\(index + 1) \(translate(filter.labelKey) ?? filter.english)", filter.name)
            }
    }
}
