import Foundation

/// One attachment site: a script bound to one property of one object (docs/scenescript-plan.md
/// §4.3). Property binding (WP8) builds these from `scene.json`; the runtime compiles and runs them
/// in the order they were added, which is scene order.
struct SceneScriptInstance {
    /// Stable, unique within a runtime, and safe to log: `<workshop id>/<object name>#<object id>/<field>`.
    /// Logs name a script by this id and a line, never by its source.
    var id: String
    var source: String
    /// The value `init`/`update` receive first (a JavaScript-convertible value).
    var initialValue: Any
    /// The `scriptproperties` values as JSON, injected through WE's `_Internal.updateScriptProperties`.
    var scriptPropertiesJSON: String?
    /// The object the script belongs to in the object table (WP7), or nil for scene-level scripts.
    var objectSlot: Int?
    /// The property the script is bound to, which makes `thisObject` that property's owner (an
    /// effect, a material, the scene; plan §1.3, P9). Nil: the layer, or the scene without a slot.
    var binding: SceneScriptObjectBinding?

    init(id: String, source: String, initialValue: Any = NSNull(), scriptPropertiesJSON: String? = nil,
         objectSlot: Int? = nil, binding: SceneScriptObjectBinding? = nil) {
        self.id = id
        self.source = source
        self.initialValue = initialValue
        self.scriptPropertiesJSON = scriptPropertiesJSON
        self.objectSlot = objectSlot
        self.binding = binding
    }

    /// The URL JavaScriptCore reports in errors and stacks.
    var sourceURL: URL? { URL(string: "owe://script/" + (id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")) }
}
