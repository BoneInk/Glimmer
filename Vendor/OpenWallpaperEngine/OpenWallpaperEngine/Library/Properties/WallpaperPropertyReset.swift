import Foundation

/// What WE's Reset button in a wallpaper's properties (`callbackResetCurrentWallpaperProperties`
/// in its `ui/dist/scripts/scripts.js`) resets, over the app's property store.
///
/// WE copies the wallpaper's `defaultproperties` (project.json's values, with its built-in
/// playback `rate` at 100) over the selected monitor's properties and applies each one live. WE
/// has no Scene Edit / Export. The app keeps Scene Edit / Export's edits in the same store, and its
/// Reset clears them too, so the wallpaper is as its author made it; the inspector's own Reset
/// clears only them (`values(removingSceneInspectorEditsFrom:)`).
enum WallpaperPropertyReset {
    /// The key prefixes of Scene Edit / Export's edits: object JSON, origin, scale and
    /// visibility (`sceneObjectVisibilityKey`), package-file JSON, and authored effect overrides
    /// (`sceneAuthoredEffectOverrideKey`, `sceneAuthoredEffectEnabledKey`) with their music sync.
    static let sceneInspectorPrefixes = ["_owe_scene_object_", "_owe_scene_asset_", "_owe_authored_effect_"]

    static func isSceneInspectorEdit(_ key: String) -> Bool {
        sceneInspectorPrefixes.contains { key.hasPrefix($0) }
    }

    /// Scene Edit / Export's edits among `stored`.
    static func sceneInspectorEdits(in stored: [String: String]) -> [String: String] {
        stored.filter { isSceneInspectorEdit($0.key) }
    }

    /// `stored` after a reset: every property at `defaults` (each property the Details panel
    /// shows, at the author's value); everything else the user set, Scene Edit / Export's edits
    /// included, dropped.
    static func values(resetting stored: [String: String], to defaults: [String: String]) -> [String: String] {
        defaults.filter { !isSceneInspectorEdit($0.key) }
    }

    /// `stored` without Scene Edit / Export's edits (its own Reset).
    static func values(removingSceneInspectorEditsFrom stored: [String: String]) -> [String: String] {
        stored.filter { !isSceneInspectorEdit($0.key) }
    }
}
