//
//  SceneEffectOverride.swift
//  Open Wallpaper Engine
//

/// A user's inspector edit of one effect parameter.
struct SceneEffectOverride: Equatable {
    /// The user property holding the edit (`sceneAuthoredEffectOverrideKey`).
    let property: String
    /// The edited value as a WE value string ("0.4", "1 0.5 0").
    let value: String
    /// True when the value, or any of its components, follows the music.
    let isMusicSynced: Bool

    init(property: String, value: String, isMusicSynced: Bool = false) {
        self.property = property
        self.value = value
        self.isMusicSynced = isMusicSynced
    }

    /// The edit stored under `property`, if any. `lookup` reads the wallpaper's user properties.
    /// Music sync is keyed `<property>_musicSync` for a scalar and `<property>_<i>_musicSync` per
    /// component of a vector (as the inspector writes them).
    static func stored(property: String, lookup: (String) -> String?) -> SceneEffectOverride? {
        guard let value = lookup(property) else { return nil }
        let count = max(1, ShaderValue(string: value)?.components.count ?? 1)
        let syncKeys = ["\(property)_musicSync"] + (0..<count).map { "\(property)_\($0)_musicSync" }
        let synced = syncKeys.contains { lookup($0)?.lowercased() == "true" }
        return SceneEffectOverride(property: property, value: value, isMusicSynced: synced)
    }
}
