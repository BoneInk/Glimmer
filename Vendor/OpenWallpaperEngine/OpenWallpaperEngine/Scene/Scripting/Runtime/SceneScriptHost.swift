import Foundation

/// What a runtime needs from the wallpaper instance that owns it. Audio, media, input and storage
/// sources are not here: each belongs to the runtime extension that uses it (see
/// `SceneScriptRuntimeExtension` and the Seams section of docs/scenescript-plan.md).
protocol SceneScriptHost: AnyObject {
    /// This wallpaper instance: `localStorage` scopes and logs are keyed on it.
    var identity: SceneScriptIdentity { get }
    /// WE's script prelude; `SceneScriptPrelude.load()` reads it from the assets directory.
    var prelude: SceneScriptPrelude { get }
    /// Every distinct error, once, after it was logged. Optional.
    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError)
}

extension SceneScriptHost {
    func runtime(_ runtime: SceneScriptRuntime, didReport error: SceneScriptError) {}
}

/// Which wallpaper instance a runtime belongs to.
struct SceneScriptIdentity: Hashable {
    /// The Steam folder id, or a stable hash of the wallpaper directory for other folders
    /// (`SceneScriptStorageKey`); never project.json's `workshopid`.
    var wallpaperID: String
    /// The display the instance renders on (`localStorage` `'screen'` scope).
    var screenID: String
}
