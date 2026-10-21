import Foundation

/// The system preference values for a colour under the user's settings.
public enum ThemePlan {
    /// The values to store; a key mapped to nil is removed (Multicolor's `AppleAccentColor`).
    /// `currentIconTheme` is the stored icon style, whose light/dark variant a tinted style keeps.
    /// Empty without a colour or with nothing on: everything is restored.
    public static func preferences(for color: ThemeColor?, settings: ThemingSettings,
                                   currentIconTheme: PreferenceValue?) -> [SystemPreferenceKey: PreferenceValue?] {
        guard let color, settings.wantsPreferences else { return [:] }
        var values: [SystemPreferenceKey: PreferenceValue?] = [:]
        if settings.accentColor {
            switch settings.systemAccent {
            case .nearestApple: values[.accentColor] = .some(.integer(AccentPalette.nearest(to: color).rawValue))
            case .multicolor: values[.accentColor] = .some(nil)
            }
            // The highlight takes a custom colour, so it is the colour in both choices.
            values[.highlightColor] = .string(HighlightColor.preferenceValue(for: color))
        }
        if settings.tintedIcons {
            values[.iconAppearanceTheme] = .string(tintedTheme(keepingVariantOf: currentIconTheme))
        }
        // The tinted style and folders share one colour: "Icon, widget & folder color".
        if settings.tintedIcons || settings.folderColor {
            values[.iconTintColor] = .string("Other")
            values[.iconCustomTintColor] = .string(color.componentString + " 1.000000")
        }
        return values
    }

    /// `Tinted` with the variant of `theme` (Automatic, Light or Dark); Automatic when unknown.
    public static func tintedTheme(keepingVariantOf theme: PreferenceValue?) -> String {
        let variants = ["Automatic", "Light", "Dark"]
        guard case .string(let name)? = theme,
              let variant = variants.first(where: { name.hasSuffix($0) }) else { return "TintedAutomatic" }
        return "Tinted" + variant
    }
}
