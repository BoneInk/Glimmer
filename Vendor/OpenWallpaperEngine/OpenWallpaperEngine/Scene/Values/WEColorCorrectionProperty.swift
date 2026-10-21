import Foundation

/// The colour options WE adds to every wallpaper's properties (its "Image filter" and "Show
/// color options"), by their WE keys. `wallpaper64.exe` injects them into a wallpaper's user
/// properties (0x140107160…0x140108bba) and reads them back when it (re)applies the properties
/// (0x140182336…0x14018262f), whatever the wallpaper authored.
enum WEColorCorrectionProperty: String, CaseIterable {
    /// "Image filter": a LUT in `materials/lut` (`combolutfilters`), "" for none.
    case filter = "wcc_v"
    /// "Filter strength": 0…100, default 100; shown while a filter is chosen.
    case filterStrength = "wcc_amt"
    /// "Show color options": off by default.
    case showColorOptions = "wec_e"
    /// "Brightness", "Contrast", "Saturation", "Hue shift": 0…100, default 50; shown with the options.
    case brightness = "wec_brs"
    case contrast = "wec_con"
    case saturation = "wec_sa"
    case hueShift = "wec_hue"

    /// WE's label (a `locale/ui_en-us.json` key) and its English text.
    var label: (key: String, english: String) {
        switch self {
        case .filter: return ("ui_browse_properties_image_filter", "Image filter")
        case .filterStrength: return ("ui_browse_properties_filter_strength", "Filter strength")
        case .showColorOptions: return ("ui_browse_properties_show_color_options", "Show color options")
        case .brightness: return ("ui_browse_properties_brightness", "Brightness")
        case .contrast: return ("ui_browse_properties_contrast", "Contrast")
        case .saturation: return ("ui_browse_properties_saturation", "Saturation")
        case .hueShift: return ("ui_browse_properties_hue_shift", "Hue shift")
        }
    }

    /// The default WE writes for the property (as a user-property string).
    var defaultValue: String {
        switch self {
        case .filter: return ""
        case .filterStrength: return "100"
        case .showColorOptions: return "false"
        case .brightness, .contrast, .saturation, .hueShift: return "50"
        }
    }

    /// WE's `condition`: the property shows while it holds.
    var condition: String? {
        switch self {
        case .filter, .showColorOptions: return nil
        case .filterStrength: return "wcc_v.value"
        case .brightness, .contrast, .saturation, .hueShift: return "wec_e.value"
        }
    }

    /// Every one of them is applied by the post-processing each frame; none rebuilds the scene.
    static func contains(_ key: String) -> Bool { Self(rawValue: key) != nil }
}
