import Foundation

/// The accent colours of System Settings › Appearance › Color. macOS takes only these: the
/// accent is the global preference `AppleAccentColor`, an integer, absent for Multicolor. It has
/// no custom accent, so a scheme colour maps to the entry that looks closest (OKLab distance).
public enum AccentPalette: Int, CaseIterable, Sendable {
    case graphite = -1
    case red = 0
    case orange = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5
    case pink = 6

    /// The entry's colour as the light appearance draws it (`controlAccentColor`).
    public var color: ThemeColor {
        switch self {
        case .graphite: return ThemeColor(red: 0.549, green: 0.549, blue: 0.549)
        case .red: return ThemeColor(red: 0.878, green: 0.220, blue: 0.243)
        case .orange: return ThemeColor(red: 0.969, green: 0.510, blue: 0.106)
        case .yellow: return ThemeColor(red: 1.000, green: 0.776, blue: 0.000)
        case .green: return ThemeColor(red: 0.384, green: 0.729, blue: 0.275)
        case .blue: return ThemeColor(red: 0.000, green: 0.478, blue: 1.000)
        case .purple: return ThemeColor(red: 0.584, green: 0.239, blue: 0.588)
        case .pink: return ThemeColor(red: 0.969, green: 0.310, blue: 0.620)
        }
    }

    /// The entry that looks closest to `color`.
    public static func nearest(to color: ThemeColor) -> AccentPalette {
        let target = OKLab(color)
        var best = AccentPalette.blue
        var bestDistance = Double.infinity
        for entry in allCases {
            let distance = OKLab(entry.color).distance(to: target)
            if distance < bestDistance {
                best = entry
                bestDistance = distance
            }
        }
        return best
    }
}

/// The text highlight colour, the global preference `AppleHighlightColor`: "r g b Name", where a
/// custom colour is named `Other` (System Settings › Appearance › Text highlight color › Other).
public enum HighlightColor {
    /// How far a highlight is from white: macOS's own highlights are their accent at about 30%
    /// over white (Blue's accent 0 0.478 1 has the highlight 0.698 0.843 1).
    public static let accentAmount = 0.3

    /// The custom highlight for `color`: light enough for text over it to stay readable.
    public static func preferenceValue(for color: ThemeColor) -> String {
        ThemeColor.white.mixed(with: color, amount: accentAmount).componentString + " Other"
    }
}
