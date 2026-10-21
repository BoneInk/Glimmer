import Foundation

/// The wallpaper's scheme colour: `general.properties.schemecolor` of its project.json, which the
/// user may change like any user property.
public enum SchemeColorSource {
    /// The property's name.
    public static let propertyName = "schemecolor"

    /// The colour the wallpaper runs with: the running instance's value (it follows live edits
    /// and presets), else the value the user saved, else project.json's. Nil when none parses.
    public static func resolve(running: [String: String], userSet: [String: String],
                               projectValue: String?) -> ThemeColor? {
        for candidate in [running[propertyName], userSet[propertyName], projectValue] {
            if let text = candidate, let color = ThemeColor(weString: text) { return color }
        }
        return nil
    }
}
