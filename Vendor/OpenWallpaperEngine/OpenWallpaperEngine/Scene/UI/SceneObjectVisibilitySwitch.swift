/// Scene Edit / Export's visibility switch of one scene object, kept in the wallpaper's store
/// under `sceneObjectVisibilityKey`, which `SceneUserVisibility` reads before the object's `visible`.
///
/// On an object a user property shows (`{"visible": {"user": …}}`), the switch works as the
/// Wallpaper Editor's eye does (`SceneEditSession.setVisible`): off hides the object whatever the
/// property says (`"false"`), and on drops the key, so the property sets it again. On any other
/// object it stores the value it is set to.
struct SceneObjectVisibilitySwitch: Equatable {
    let objectID: Int
    /// The user property that sets the object's `visible`, if one does.
    let property: String?
    /// The authored `visible` (a bound one's `value`), WE's true when absent.
    let authored: Bool

    var key: String { sceneObjectVisibilityKey(objectID: objectID) }

    /// The switch as `values` have it: off only while hidden by it, or, on an unbound object, while
    /// its authored `visible` hides it.
    func isOn(_ values: [String: String]) -> Bool {
        if let stored = values[key] { return stored != "false" }
        return property != nil || authored
    }

    /// Drawn as far as the switch and the authored `visible` say: the rows' dimming. A bound
    /// object's property value isn't known here; its authored `value` stands for it.
    func isShown(_ values: [String: String]) -> Bool {
        values[key].map { $0 != "false" } ?? authored
    }

    /// `values` with the switch set to `on`.
    func values(_ values: [String: String], settingOn on: Bool) -> [String: String] {
        var values = values
        values[key] = on ? (property == nil ? "true" : nil) : "false"
        return values
    }
}
