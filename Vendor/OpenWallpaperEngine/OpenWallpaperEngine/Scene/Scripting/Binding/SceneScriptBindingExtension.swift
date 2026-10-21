import Foundation
import JavaScriptCore

/// Property binding (docs/scenescript-plan.md WP8): what `init(value)` and `update(value)` receive
/// and what happens to their return, for every script bound to a scene.json property.
///
/// - The argument is the property's live value (§1.9 P2): read through the object model when the
///   property is one of its members (layer, particle instance, effect, material constant, scene
///   setting), so writes by other scripts and the renderer show; otherwise the value the script's
///   last applied return left. Vectors are fresh `Vec`s on every call.
/// - A return is checked by WE's converter for the property's type (`SceneScriptPropertyType`);
///   an accepted one becomes the property's value (written through the object model) and the next
///   call's argument, a rejected one or `undefined` changes nothing (P3). `init`'s return seeds it.
/// - When a user property changes, the values and `scriptproperties` entries bound to it take the
///   new value before the frame's `applyUserProperties` (through WE's
///   `_Internal.updateScriptProperties` for script properties).
///
/// Install it with the object model; the order of extensions does not matter. Register each site
/// with `add(_:to:)` (or `bind` before adding the instance yourself) before the `load` that
/// defines it.
final class SceneScriptBindingExtension: SceneScriptRuntimeExtension {
    let scriptResources = ["sceneScriptBinding"]

    /// Registers how the script `site.instance.id` is bound. On the runtime's thread.
    func bind(_ site: SceneScriptSite, in runtime: SceneScriptRuntime) {
        runtime.rt.forProperty("binding")?.invokeMethod("bind", withArguments: [site.instance.id,
                                                                               site.property.javaScriptObject])
    }

    /// Registers every site and adds its instance to `runtime`, in order (scene order is the
    /// order scripts run in). On the runtime's thread, before `load`.
    func add(_ sites: [SceneScriptSite], to runtime: SceneScriptRuntime) {
        for site in sites {
            bind(site, in: runtime)
            runtime.add(site.instance)
        }
    }
}
