import Foundation

/// The global (`NSGlobalDomain`) preferences theming may change. Each was found by reading this
/// Mac's preferences and the system's own strings (System Settings › Appearance, SkyLight); see
/// docs/theming.md.
public enum SystemPreferenceKey: String, CaseIterable, Codable, Sendable {
    /// Appearance › Color: an integer of `AccentPalette`, absent for Multicolor.
    case accentColor = "AppleAccentColor"
    /// Appearance › Text highlight color: "r g b Name", `Other` for a custom colour.
    case highlightColor = "AppleHighlightColor"
    /// Appearance › Icon & widget style: `{Regular|Clear|Tinted}{Automatic|Light|Dark}`.
    case iconAppearanceTheme = "AppleIconAppearanceTheme"
    /// Appearance › Icon, widget & folder color: a palette name (Red … Graphite) or `Other`;
    /// absent follows the accent colour.
    case iconTintColor = "AppleIconAppearanceTintColor"
    /// The `Other` icon, widget and folder colour: "r g b a".
    case iconCustomTintColor = "AppleIconAppearanceCustomTintColor"

    /// The system notification apps listen to for a change of this preference.
    public var change: SystemAppearanceChange {
        switch self {
        case .accentColor, .highlightColor: return .colorPreferences
        case .iconAppearanceTheme, .iconTintColor, .iconCustomTintColor: return .iconAppearance
        }
    }
}

/// A stored preference value: the two kinds the keys above hold.
public enum PreferenceValue: Equatable, Hashable, Codable, Sendable {
    case integer(Int)
    case string(String)
}

/// What changed, for the notification apps update on.
public enum SystemAppearanceChange: Hashable, Sendable, CaseIterable {
    /// The accent or highlight colour: the distributed notification
    /// `AppleColorPreferencesChangedNotification`, which System Settings posts and AppKit observes.
    case colorPreferences
    /// The icon style or tint. SkyLight applies it to the Dock and Finder; there is no public
    /// notification, so the Dock picks it up when it restarts (`DockRestartScheduler`).
    case iconAppearance

    /// The distributed notifications posted, in order, once the values are stored: what System
    /// Settings › Appearance posts for an accent or highlight change (the names in its binaries,
    /// docs/theming.md). AppKit re-reads the accent colour on `AppleAquaColorVariantChanged`, the
    /// highlight colour on `AppleColorPreferencesChangedNotification`, and redraws its dynamic
    /// colours on `AppleInterfaceThemeChangedNotification`. Without them running apps keep the old
    /// colours until System Settings next opens and posts them.
    public var notificationNames: [String] {
        switch self {
        case .colorPreferences:
            return ["AppleAquaColorVariantChanged", "AppleColorPreferencesChangedNotification",
                    "AppleInterfaceThemeChangedNotification"]
        case .iconAppearance:
            return []
        }
    }
}
