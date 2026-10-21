import Foundation

/// Saved display profiles, WE's "Save profile" / "Load profile": the displays' wallpapers and
/// layout under a name. An application rule's "Load profile" loads one by name (WE's
/// `loadprofile`), and its editor lists them. The app's are `DisplayProfiles`.
@MainActor
protocol DisplayProfileLoading: AnyObject {
    /// The saved profiles' names, in the order the user sees them.
    var profileNames: [String] { get }
    /// Loads the profile named `name`; false when there is none by that name.
    func load(name: String) -> Bool
}

extension DisplayProfiles: DisplayProfileLoading {
    var profileNames: [String] { names }
}

/// No profiles to list or load: the rule editor's in previews and tests, and the app's once its
/// view model is gone.
@MainActor
final class UnavailableDisplayProfiles: DisplayProfileLoading {
    var profileNames: [String] { [] }
    func load(name: String) -> Bool { false }
}
