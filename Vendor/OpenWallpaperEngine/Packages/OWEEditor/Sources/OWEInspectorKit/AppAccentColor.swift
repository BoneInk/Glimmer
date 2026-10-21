import SwiftUI

private struct AppAccentColorKey: EnvironmentKey {
    static let defaultValue = Color.accentColor
}

extension EnvironmentValues {
    /// The accent the app draws its own selection marks, gizmos and indicators in: Theming's exact
    /// colour when the app follows it, else `Color.accentColor`. Set at each window's root, with
    /// `.tint`, by the app (`AppAccentTint`).
    public var appAccentColor: Color {
        get { self[AppAccentColorKey.self] }
        set { self[AppAccentColorKey.self] = newValue }
    }
}
