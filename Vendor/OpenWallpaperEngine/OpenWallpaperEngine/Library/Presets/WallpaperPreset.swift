import Foundation

/// A named set of a wallpaper's user-property values, WE's "Your Presets" in its Details panel.
///
/// `values` is the whole property store of the display it was saved from: the project.json
/// properties, the app's own adjustments and Scene Edit / Export's edits, which share that store
/// (`WallpaperPropertyReset.sceneInspectorPrefixes`). Applying it replaces the store, so a
/// property the preset doesn't name goes back to its default.
struct WallpaperPreset: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var created: Date
    var values: [String: String]

    init(id: UUID = UUID(), name: String, created: Date = Date(), values: [String: String]) {
        self.id = id
        self.name = name
        self.created = created
        self.values = values
    }
}
