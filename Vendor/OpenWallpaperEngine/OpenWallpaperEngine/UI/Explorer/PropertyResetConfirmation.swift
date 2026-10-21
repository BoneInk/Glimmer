import Foundation

/// The texts of the Details panel's Reset confirmation, WE's `genericConfirm` with
/// `ui_browse_details_properties_reset_prompt_header` and `_prompt_body`, naming the wallpaper
/// and the displays the reset reaches (`WallpaperViewModel.editedPropertyScopes`).
enum PropertyResetConfirmation {
    static var title: String {
        String(localized: "Reset Properties", comment: "Title of the confirmation before a wallpaper's properties are reset to their defaults (Wallpaper Engine's wording)")
    }

    static var help: String {
        String(localized: "Reset this wallpaper's properties to the defaults its author set", comment: "Help for the Details panel's Reset button")
    }

    /// `scopes`: the stores the reset rewrites, `[.shared]` while properties are synced.
    static func message(title: String, scopes: [WallpaperPropertyScope]) -> String {
        let question = String(localized: "Do you want to reset the properties of “\(title)” back to their defaults?",
                              comment: "Reset confirmation; the wallpaper's title (Wallpaper Engine's wording)")
        let reach: String
        if scopes.contains(.shared) {
            reach = String(localized: "Properties are synced across displays, so every display showing it is reset.",
                           comment: "Reset confirmation, when one set of properties serves every display")
        } else if scopes.count > 1 {
            reach = String(localized: "Only the selected displays are reset.", comment: "Reset confirmation, several displays selected")
        } else {
            reach = String(localized: "Only the selected display is reset.", comment: "Reset confirmation, one display selected")
        }
        let inspector = String(localized: "Scene edits are reset too.", comment: "Reset confirmation: Scene Edit / Export's edits go as well")
        return [question, reach, inspector].joined(separator: " ")
    }
}
