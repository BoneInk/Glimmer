import Foundation

/// Settings › General › Theming. Every target is off by default, as is the master switch.
public struct ThemingSettings: Equatable, Codable, Sendable {
    /// The master switch: off, nothing is themed and everything theming changed is restored.
    public var isEnabled = false
    /// Fills the menu bar's strip of the desktop picture OWE sets with the colour.
    public var menuBar = false
    /// System Settings › Appearance › Color (`systemAccent`) and the text highlight, and the
    /// accent of Open Wallpaper Engine's own windows (`appAccent`).
    public var accentColor = false
    /// What Accent Color makes the system-wide accent: the nearest of macOS's eight (every app
    /// follows it) or Multicolor (each app keeps its own). The nearest by default, as before.
    public var systemAccent = SystemAccentChoice.nearestApple
    /// Open Wallpaper Engine's own controls, selection and links: the colour itself, or the system
    /// accent. The colour by default.
    public var appAccent = AppAccentChoice.themeColor
    /// Appearance › Icon & widget style › Tinted, in the colour.
    public var tintedIcons = false
    /// Appearance › Icon, widget & folder color.
    public var folderColor = false
    /// Without a scheme colour, the main colour of the wallpaper's snapshot is used.
    public var usesDominantColor = false
    /// Quitting puts the user's preferences back. On by default.
    public var restoresOnQuit = true
    /// The Dock restarts by itself once a new icon or folder colour settles, so it shows it. On by
    /// default; off, Settings offers a button instead.
    public var restartsDockAutomatically = true

    public init() {}

    /// Whether any system preference is wanted (the menu bar strip is a picture, not a preference).
    public var wantsPreferences: Bool { isEnabled && (accentColor || tintedIcons || folderColor) }

    /// Whether the menu bar strip is drawn.
    public var wantsMenuBarStrip: Bool { isEnabled && menuBar }

    /// Whether anything at all is themed, which is when the colour needs finding.
    public var wantsColor: Bool { wantsPreferences || wantsMenuBarStrip }

    /// The tint of Open Wallpaper Engine's own windows for `color`: the colour itself while Accent
    /// Color is on and the app follows the theme; nil (the system accent) otherwise.
    public func appTint(for color: ThemeColor?) -> ThemeColor? {
        guard isEnabled, accentColor, appAccent == .themeColor else { return nil }
        return color
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled, menuBar, accentColor, tintedIcons, folderColor, usesDominantColor, restoresOnQuit
        case restartsDockAutomatically, systemAccent, appAccent
    }

    /// Reads each key on its own: a missing or unreadable one keeps its default.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func read<Value: Decodable>(_ key: CodingKeys, _ value: inout Value) {
            if let stored = try? container.decodeIfPresent(Value.self, forKey: key) { value = stored } // Optional: a bad key keeps its default.
        }
        read(.isEnabled, &isEnabled)
        read(.menuBar, &menuBar)
        read(.accentColor, &accentColor)
        read(.tintedIcons, &tintedIcons)
        read(.folderColor, &folderColor)
        read(.usesDominantColor, &usesDominantColor)
        read(.restoresOnQuit, &restoresOnQuit)
        read(.restartsDockAutomatically, &restartsDockAutomatically)
        read(.systemAccent, &systemAccent)
        read(.appAccent, &appAccent)
    }
}

/// What Accent Color makes System Settings › Appearance › Color. macOS has only eight accents and
/// no custom one.
public enum SystemAccentChoice: String, Codable, CaseIterable, Sendable {
    /// `AppleAccentColor` is the palette entry closest to the colour: every app follows it.
    case nearestApple
    /// `AppleAccentColor` is removed (Multicolor): each app uses its own accent.
    case multicolor
}

/// The accent of Open Wallpaper Engine's own windows while Accent Color is on.
public enum AppAccentChoice: String, Codable, CaseIterable, Sendable {
    /// The colour itself, which the system palette can't show.
    case themeColor
    /// The system accent, as other apps show it.
    case system
}
