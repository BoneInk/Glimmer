import Foundation

extension SceneEngineCombos {
    /// Shadow maps are drawn: the shadows setting is on and the (folded) budget has a shadowed
    /// light (docs/models-plan.md §2.10), so opaque model materials get their shadow variant.
    var castsShadows: Bool {
        guard shadowQuality > 0, let budget = lightBudget else { return false }
        return budget.spotShadowCookie + budget.spotShadow + budget.directionalShadow + budget.pointShadow != 0
    }

    /// The lighting part of WE's engine combos (0x1401a5c40; docs/lighting-plan.md §2.2):
    /// - when the material's `LIGHTING` is set and not 0, all nine `LIGHTS_*` counts from
    ///   `lightBudget` (0 without a `lightconfig`, as WE's budget word is then 0);
    ///   `LIGHTS_SHADOW_MAPPING` = 1 and `LIGHTS_SHADOW_MAPPING_QUALITY` = `shadowQuality` when a
    ///   shadowed count (spot shadow and cookie, spot shadow, directional shadow, point shadow)
    ///   is not 0; `LIGHTS_COOKIE` = 1 when a cookie count (spot cookie, spot shadow and cookie)
    ///   is not 0;
    /// - `SCENE_ORTHO` = 1 on every material while the scene is orthographic (render flag 0x400).
    func lightingCombos(for material: [String: Int]) -> [String: Int] {
        var combos: [String: Int] = [:]
        if let lighting = material["LIGHTING"], lighting != 0 {
            let budget = lightBudget ?? WELightConfig()
            combos["LIGHTS_POINT"] = budget.point
            combos["LIGHTS_SPOT"] = budget.spot
            combos["LIGHTS_TUBE"] = budget.tube
            combos["LIGHTS_DIRECTIONAL"] = budget.directional
            combos["LIGHTS_SPOT_SHADOW_COOKIE"] = budget.spotShadowCookie
            combos["LIGHTS_SPOT_SHADOW"] = budget.spotShadow
            combos["LIGHTS_SPOT_COOKIE"] = budget.spotCookie
            combos["LIGHTS_DIRECTIONAL_SHADOW"] = budget.directionalShadow
            combos["LIGHTS_POINT_SHADOW"] = budget.pointShadow
            if budget.spotShadowCookie + budget.spotShadow + budget.directionalShadow + budget.pointShadow != 0 {
                combos["LIGHTS_SHADOW_MAPPING"] = 1
                combos["LIGHTS_SHADOW_MAPPING_QUALITY"] = shadowQuality
            }
            if budget.spotCookie + budget.spotShadowCookie != 0 {
                combos["LIGHTS_COOKIE"] = 1
            }
        }
        if sceneOrtho { combos["SCENE_ORTHO"] = 1 }
        return combos
    }
}
