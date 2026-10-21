import Foundation

/// Which typed target a bound value resolves to and what its change invalidates, from where it
/// sits. Anything not recognised is `.other` and structural for its owner: rebuilding the owner
/// is always correct, only slower, so no binding is ever ignored.
///
/// Applied in place (`uniform`): shader constants (`constantshadervalues` of an object's effect
/// passes, of its own material `instance`, of a material or effect document; `usershadervalues`),
/// which the uniform builders resolve from the binding.
///
/// Applied to the owner's state (`object`), the sites the renderer takes from their binding
/// (`SceneLiveBindingSites`): an object's transform (not a light's, whose depth is captured at
/// build) and the colour of image and text layers, `visible` of objects and their effects, a
/// particle system's `instanceoverride` but `count`, the `animationlayers` controls a puppet reads
/// each frame, and values scripts drive or read (`scriptproperties`).
///
/// Everything else is `structural`: combos, textures, sizes (`size`, `pointsize`, a text's string,
/// which sizes its raster, `instanceoverride.count`, which sizes the particle budget), `general`,
/// lights, sounds and models, and the fields of effect, material and particle documents besides
/// their constants.
enum UserPropertyBindingClassifier {
    struct Classification: Equatable {
        let target: UserPropertyBindingTarget
        let dependency: UserPropertyBindingDependency
        let owner: UserPropertyBindingOwner
    }

    /// `node` is the bound value's object (holding `user`); `root` the document.
    static func classify(_ path: UserPropertyBindingPath, node: [String: SceneJSON],
                         document: UserPropertyBindingDocument, root: SceneJSON) -> Classification {
        if path.components.contains(.key("scriptproperties")) || isScripted(node) {
            let owner = document == .scene ? sceneOwner(path, root: root) : .scene
            return Classification(target: .scriptValue(path.description), dependency: .object, owner: owner)
        }
        switch document {
        case .scene: return classifyScene(path, root: root)
        case .asset: return classifyAsset(path, from: 0, effect: nil)
        }
    }

    /// A `usershadervalues` entry of a material document's pass: constant `key` follows the property.
    static func userShaderValue(key: String) -> Classification {
        Classification(target: .userShaderValue(key: key), dependency: .uniform, owner: .scene)
    }

    /// A value with a script: the script owns it from its first run and reads the user binding as
    /// its start (`SceneValueSource`), so the change reaches it through `applyUserProperties`.
    private static func isScripted(_ node: [String: SceneJSON]) -> Bool {
        if case .string(let script)? = node["script"], !script.isEmpty { return true }
        return false
    }

    /// `general` fields the renderer reads every frame (`SceneMetalRenderer.refreshCamera()`):
    /// the camera parallax, which turns on and off without a content rebuild.
    static let liveGeneralFields: Set<UserPropertyBindingTarget> = Set(
        [SceneGeneralValueField.cameraparallax, .cameraparallaxamount, .cameraparallaxdelay,
         .cameraparallaxmouseinfluence].map { UserPropertyBindingTarget.general($0.rawValue) })

    private static func classifyScene(_ path: UserPropertyBindingPath, root: SceneJSON) -> Classification {
        guard path.key(at: 0) == "objects", let index = path.index(at: 1) else {
            let target: UserPropertyBindingTarget = path.key(at: 0) == "general" && path.count == 2
                ? .general(path.key(at: 1) ?? "") : .other(path.description)
            return Classification(target: target, dependency: liveGeneralFields.contains(target) ? .object : .structural,
                                  owner: .scene)
        }
        let owner = objectOwner(index, root: root)
        let object = objectFields(index, root: root)
        func result(_ target: UserPropertyBindingTarget, _ dependency: UserPropertyBindingDependency) -> Classification {
            Classification(target: target, dependency: dependency, owner: owner)
        }
        guard let field = path.key(at: 2) else { return result(.other(path.description), .structural) }
        let rest = path.count - 3
        switch field {
        case "visible" where rest == 0:
            return result(.objectVisible, .object)
        case "text" where rest == 0:
            return result(.text, .structural)
        case "effects":
            guard let effect = path.index(at: 3) else { return result(.other(path.description), .structural) }
            if path.key(at: 4) == "visible", path.count == 5 { return result(.effectVisible(effect: effect), .object) }
            let classified = classifyAsset(path, from: 4, effect: effect)
            return result(classified.target, classified.dependency)
        case "instance":
            let classified = classifyPassField(path, from: 3, effect: nil, pass: 0)
            return result(classified.target, classified.dependency)
        case "instanceoverride":
            guard rest == 1, let key = path.key(at: 3) else { return result(.other(path.description), .structural) }
            let live = object["particle"] != nil && SceneLiveBindingSites.isLiveInstanceOverride(key)
            return result(.instanceOverride(key), live ? .object : .structural)
        case "animationlayers":
            guard let layer = path.index(at: 3), let key = path.key(at: 4), path.count == 5 else {
                return result(.other(path.description), .structural)
            }
            let live: Set<String> = ["rate", "blend", "visible"]
            return result(.animationLayer(layer: layer, field: key), live.contains(key) ? .object : .structural)
        default:
            guard rest == 0, let value = SceneObjectValueField(rawValue: field) else {
                return result(.other(path.description), .structural)
            }
            let live = SceneLiveBindingSites.isLive(field, of: object)
            return result(.objectField(value), live ? .object : .structural)
        }
    }

    /// A path inside an effect entry or an effect or material document: `passes[p]…`.
    private static func classifyAsset(_ path: UserPropertyBindingPath, from start: Int, effect: Int?) -> Classification {
        guard path.key(at: start) == "passes", let pass = path.index(at: start + 1) else {
            return Classification(target: .other(path.description), dependency: .structural, owner: .scene)
        }
        return classifyPassField(path, from: start + 2, effect: effect, pass: pass)
    }

    private static func classifyPassField(_ path: UserPropertyBindingPath, from start: Int, effect: Int?,
                                          pass: Int) -> Classification {
        guard let key = path.key(at: start + 1), path.count == start + 2 else {
            return Classification(target: .other(path.description), dependency: .structural, owner: .scene)
        }
        switch path.key(at: start) {
        case "constantshadervalues":
            return Classification(target: .shaderConstant(effect: effect, pass: pass, key: key), dependency: .uniform, owner: .scene)
        case "combos":
            return Classification(target: .combo(effect: effect, pass: pass, key: key), dependency: .structural, owner: .scene)
        default:
            return Classification(target: .other(path.description), dependency: .structural, owner: .scene)
        }
    }

    private static func sceneOwner(_ path: UserPropertyBindingPath, root: SceneJSON) -> UserPropertyBindingOwner {
        guard path.key(at: 0) == "objects", let index = path.index(at: 1) else { return .scene }
        return objectOwner(index, root: root)
    }

    /// Object `index`'s id, else its index (`SceneObjectIdentity.assigningFallbackIDs`).
    static func objectOwner(_ index: Int, root: SceneJSON) -> UserPropertyBindingOwner {
        if case .number(let id)? = objectFields(index, root: root)["id"] { return .object(Int(id)) }
        return .object(index)
    }

    private static func objectFields(_ index: Int, root: SceneJSON) -> [String: SceneJSON] {
        guard case .object(let fields) = root, case .array(let objects)? = fields["objects"],
              objects.indices.contains(index), case .object(let object) = objects[index] else { return [:] }
        return object
    }
}
