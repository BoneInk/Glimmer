//
//  AppAccentTint.swift
//  Open Wallpaper Engine
//

import OWEInspectorKit
import OWETheming
import SwiftUI

/// Theming's exact colour as the accent of a window's SwiftUI content: `.tint` (buttons, toggles,
/// sliders, links, progress) and `appAccentColor` (OWEInspectorKit), which the app's and the
/// editor's own accent drawings use in place of `Color.accentColor`. Without a tint (Theming off,
/// or Settings › Theming's "Open Wallpaper Engine" set to the system accent) both are the system
/// accent. Applied at the root of every window (`appAccentTint()`).
struct AppAccentTint: ViewModifier {
    @ObservedObject var accent: SystemAccentColor

    func body(content: Content) -> some View {
        let tint = accent.themeTint.map(Color.init(themeColor:))
        content
            .tint(tint)
            .environment(\.appAccentColor, tint ?? .accentColor)
    }
}

extension View {
    /// Gives a window's content Theming's tint; see `AppAccentTint`.
    func appAccentTint(_ accent: SystemAccentColor = .shared) -> some View {
        modifier(AppAccentTint(accent: accent))
    }
}

extension Color {
    /// A theme colour, in sRGB.
    init(themeColor: ThemeColor) {
        self.init(.sRGB, red: themeColor.red, green: themeColor.green, blue: themeColor.blue, opacity: 1)
    }
}
