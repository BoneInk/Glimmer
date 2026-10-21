import Foundation

extension SceneEngineCombos {
    /// WE's fog combos (0x1401a64ae…0x1401a666a): while the scene's distance or height fog is on,
    /// a material whose `FOG` combo resolved to a value other than 0 gets `FOG_DIST` and
    /// `FOG_HEIGHT` for the fog that is on. A material without `FOG` gets neither.
    func fogCombos(for material: [String: Int]) -> [String: Int] {
        guard fogDistance || fogHeight, let fog = material["FOG"], fog != 0 else { return [:] }
        var combos: [String: Int] = [:]
        if fogDistance { combos["FOG_DIST"] = 1 }
        if fogHeight { combos["FOG_HEIGHT"] = 1 }
        return combos
    }
}
