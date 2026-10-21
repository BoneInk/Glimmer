import Foundation

/// What `thisObject` is for a script (lib.sceneScript.d.ts IThisPropertyObject; plan §1.3, P9):
/// the object owning the property the script is bound to. `property` is that property's scene.json
/// key; `thisObject.getAnimation()` without a name returns the animation that drives it.
enum SceneScriptObjectBinding: Equatable {
    /// A layer property (`alpha`, `origin`, `visible`, …) or a particle system's
    /// `instanceoverride.*` (P9: `thisObject` is the particle system).
    case layer(slot: Int, property: String)
    /// `effects[effect].visible`: `thisObject` is the `IEffect`.
    case effect(slot: Int, effect: Int, property: String)
    /// `effects[effect].passes[material].constantshadervalues[constant]`: `thisObject` is the
    /// `IMaterial`, whose constants are members by name.
    case material(slot: Int, effect: Int, material: Int, constant: String)
    /// `general.*` (P9: `thisObject` is the scene).
    case scene(property: String)

    /// The binding for scene.json field path `path` of the object in `slot` (nil for `general.*`):
    /// `alpha`, `effects.1.visible`, `effects.0.passes.0.constantshadervalues.Bar Color`,
    /// `instanceoverride.rate`, `general.bloomstrength`.
    init?(fieldPath path: String, slot: Int?) {
        let parts = path.split(separator: ".", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        if parts.first == "general" {
            guard parts.count >= 2 else { return nil }
            self = .scene(property: parts.dropFirst().joined(separator: "."))
            return
        }
        guard let slot else { return nil }
        if parts.first == "effects" {
            guard parts.count >= 3, let effect = Int(parts[1]) else { return nil }
            if parts.count == 3 {
                self = .effect(slot: slot, effect: effect, property: parts[2])
                return
            }
            guard parts.count == 6, parts[2] == "passes", let material = Int(parts[3]),
                  parts[4] == "constantshadervalues" else { return nil }
            self = .material(slot: slot, effect: effect, material: material, constant: parts[5])
            return
        }
        guard !path.isEmpty else { return nil }
        self = .layer(slot: slot, property: path)
    }

    var javaScriptObject: [String: Any] {
        switch self {
        case .layer(let slot, let property):
            return ["kind": "layer", "slot": slot, "property": property]
        case .effect(let slot, let effect, let property):
            return ["kind": "effect", "slot": slot, "effect": effect, "property": property]
        case .material(let slot, let effect, let material, let constant):
            return ["kind": "material", "slot": slot, "effect": effect, "material": material, "property": constant]
        case .scene(let property):
            return ["kind": "scene", "property": property]
        }
    }
}
