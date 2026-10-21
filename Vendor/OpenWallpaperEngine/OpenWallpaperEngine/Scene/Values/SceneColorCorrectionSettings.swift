import Foundation

/// WE's colour correction for one frame, from the colour properties
/// (`wallpaper64.exe` 0x140182336…0x140182ea3).
struct SceneColorCorrectionSettings: Equatable {
    var showColorOptions = false
    /// The sliders as the properties hold them, 0…100 (50 is no change).
    var brightness: Float = 50
    var contrast: Float = 50
    var saturation: Float = 50
    var hueShift: Float = 50
    /// A LUT's name in `materials/lut`; "" for none.
    var filter = ""
    /// 0…100.
    var filterStrength: Float = 100

    init() {}

    /// From user-property strings; a missing or unreadable value keeps WE's default.
    init(property: (WEColorCorrectionProperty) -> String?) {
        func number(_ key: WEColorCorrectionProperty, _ fallback: Float) -> Float {
            guard let text = property(key), let value = Float(text.trimmingCharacters(in: .whitespaces)),
                  value.isFinite else { return fallback }
            return value
        }
        let shown: String = property(.showColorOptions)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let shownNumber: Float = Float(shown) ?? 0
        showColorOptions = shown == "true" || shownNumber != 0
        brightness = number(.brightness, brightness)
        contrast = number(.contrast, contrast)
        saturation = number(.saturation, saturation)
        hueShift = number(.hueShift, hueShift)
        filter = property(.filter)?.trimmingCharacters(in: .whitespaces) ?? ""
        filterStrength = number(.filterStrength, filterStrength)
    }

    /// The values WE keeps (0x1401823f2…0x14018262f): contrast, brightness and saturation / 50,
    /// hue / 100 − 0.5, strength / 100.
    var contrastScale: Float { contrast / 50 }
    var brightnessScale: Float { brightness / 50 }
    var saturationScale: Float { saturation / 50 }
    var hue: Float { hueShift / 100 - 0.5 }
    /// `lutparams`: how much of the filter's colour replaces the frame's.
    var filterAmount: Float { filterStrength / 100 }

    /// `COL`: the options are shown and one of them is away from identity (0x140182638).
    var appliesColor: Bool {
        showColorOptions && !(contrastScale == 1 && brightnessScale == 1 && saturationScale == 1 && hue == 0)
    }

    /// `LUT`: a filter is chosen and its strength is above 0 (0x140182698).
    var appliesFilter: Bool { !filter.isEmpty && filterAmount > 0 }

    /// WE makes the `ccsimple` pass only when one of them applies (0x1401826e4…0x1401826f3).
    var isIdentity: Bool { !appliesColor && !appliesFilter }

    /// `g_Params` (0x140182d85…0x140182df9): brightness², √contrast, √saturation and the hue.
    var params: SIMD4<Float> {
        SIMD4(powf(brightnessScale, 2), powf(contrastScale, 0.5), powf(saturationScale, 0.5), hue)
    }
}
