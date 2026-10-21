/// What makes a scene's objects and their effects visible before scripts: authored `visible`, its
/// user binding (`{"user": …}` or `{"user": {"name", "condition"}}`) and the app's own switches.
///
/// Hidden objects and effects are built too (a script can show them), so the renderer takes the
/// user's visibility again whenever a user property changes, without a content rebuild
/// (`SceneLiveBindingSites`).
struct SceneUserVisibility: Equatable {
    /// One `visible` field: its authored value and what binds it.
    struct Gate: Equatable {
        var visible: Bool?
        var condition: String?
        var property: String?

        /// Shown: the bound property's value (a combo's equal to `condition`, else true), or the
        /// authored `visible` (default true) while the property has no value.
        func isShown(_ userProperty: (String) -> String?) -> Bool {
            guard let property else { return visible != false }
            guard let selected = userProperty(property) else { return visible != false }
            // The binding's own resolution (`UserPropertyValueConversion`), as its parser reads it.
            let value = UserPropertyValueConversion.siteValue(selected, condition: condition, default: .bool(visible != false))
            return value == .bool(true)
        }
    }

    /// One object of scene.json.
    struct Site: Equatable {
        let id: Int
        let isText: Bool
        let gate: Gate
        /// By index in the object's `effects`.
        let effects: [Gate]

        init(_ object: WESceneObject, at index: Int) {
            id = SceneObjectIdentity.id(of: object, at: index)
            isText = object.textValue != nil
            gate = Gate(visible: object.visible, condition: object.visibleCondition, property: object.visibleUserProperty)
            effects = (object.effects ?? []).map {
                Gate(visible: $0.visible, condition: $0.visibleCondition, property: $0.visibleUserProperty)
            }
        }

        /// The object's own visibility: Scene Edit / Export's switch, the text switch, then `visible`.
        func isShown(_ userProperty: (String) -> String?) -> Bool {
            if let override = userProperty(sceneObjectVisibilityKey(objectID: id)) { return override != "false" }
            if isText, userProperty("_owe_text_\(id)_enabled") == "false" { return false }
            return gate.isShown(userProperty)
        }
    }

    /// The scene's objects, in scene order (ids assigned: `SceneObjectIdentity.assigningFallbackIDs`).
    let sites: [Site]

    init(objects: [WESceneObject] = []) {
        sites = objects.enumerated().map { Site($1, at: $0) }
    }

    /// Every object's own visibility, by id, and each bound effect's, by object id and effect index.
    func resolve(_ userProperty: (String) -> String?) -> (objects: [String: Bool], effects: [String: [Int: Bool]]) {
        var objects: [String: Bool] = [:]
        var effects: [String: [Int: Bool]] = [:]
        for site in sites {
            // The first object of an id wins, as the content's layers do.
            let id = String(site.id)
            guard objects[id] == nil else { continue }
            objects[id] = site.isShown(userProperty)
            for (index, gate) in site.effects.enumerated() where gate.property != nil {
                effects[id, default: [:]][index] = gate.isShown(userProperty)
            }
        }
        return (objects, effects)
    }

    static func normalizeVariant(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
