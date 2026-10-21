import Foundation

/// A private copy of a wallpaper that one of Scene Edit / Export's modes edits apart from the
/// desktop (the iPhone & iPad Export mode's; any mode that previews and renders its own version).
///
/// When the mode opens, the values of the store the editor edits (user properties and the
/// editor's layer edits alike: visibility, transforms, blending, effect values) are copied into
/// an isolated store (`WallpaperPropertyScope.isolated`, named by `purpose`). Everything the mode
/// changes goes there: the editor's own models pointed at `scope`, or `setValues` and
/// `setLayerVisible`. The private instance (`IsolatedSceneView`) runs from this session's own
/// registry under its own key, silent and without loading snapshots, and an offscreen render
/// takes `values`. Nothing reaches a display, the shared instance, the stores the desktop runs
/// or the wallpaper's editor overlay. `end()` drops the copy.
@MainActor
final class IsolatedSceneEditSession {
    let wallpaper: WEWallpaper
    /// Names the store, so two modes' copies never mix.
    let purpose: String
    /// The isolated store, the only one this session's edits go to.
    let scope: WallpaperPropertyScope
    let targets: WallpaperPropertyTargets
    /// The session's own instances, never `WallpaperViewModel.sceneInstances`: the private
    /// instance runs here alone, even when a display shows the same wallpaper.
    let instances = WallpaperInstanceRegistry<WallpaperInstanceKey, SceneWallpaperInstance>(teardown: { $0.shutdown() })
    private let defaults: UserDefaults
    private let services: WallpaperServices
    private(set) var isEnded = false

    /// Seeds the isolated store with the values of `scopes`' shown store (`WallpaperPropertyTargets`),
    /// replacing any copy a previous session of this purpose left.
    init(wallpaper: WEWallpaper, purpose: String, seededFrom scopes: [WallpaperPropertyScope],
         defaults: UserDefaults = .app, services: WallpaperServices = .shared) {
        self.wallpaper = wallpaper
        self.purpose = purpose
        self.defaults = defaults
        self.services = services
        scope = .isolated(purpose)
        targets = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: [scope])
        let seed = Self.seed(of: wallpaper, from: scopes, defaults: defaults)
        // Saved as set by the user, so the private instance loads exactly these.
        targets.save(seed, defaults: defaults)
        services.setUserProperties(seed, wallpaper: runtimeKey, replacing: true)
    }

    /// The values a session of `wallpaper` starts from: `scopes`' shown store's.
    static func seed(of wallpaper: WEWallpaper, from scopes: [WallpaperPropertyScope],
                     defaults: UserDefaults = .app) -> [String: String] {
        let source = WallpaperPropertyTargets(wallpaper: wallpaper, scopes: scopes)
        return source.identity.stored(.userProperties, scope: source.scopes[0], defaults: defaults) as? [String: String] ?? [:]
    }

    /// The private instance's key: the wallpaper with the isolated store.
    var instanceKey: WallpaperInstanceKey { WallpaperInstanceKey(wallpaper, properties: scope) }

    /// The isolated store's key in the running stores (`SceneUserPropertyService`).
    var runtimeKey: String { scope.runtimeKey(directory: targets.directory) }

    /// The render hook: every value an offscreen render of this version takes (its user properties
    /// and layer edits), e.g. a Live Photo job's or a loop render's properties.
    var values: [String: String] {
        targets.identity.stored(.userProperties, scope: scope, defaults: defaults) as? [String: String] ?? [:]
    }

    /// The layer edits among `values` (Scene Edit / Export's keys, `WallpaperPropertyReset`).
    var layerEdits: [String: String] { WallpaperPropertyReset.sceneInspectorEdits(in: values) }

    /// The user properties among `values`.
    var properties: [String: String] { WallpaperPropertyReset.values(removingSceneInspectorEditsFrom: values) }

    /// Merges `changes` into the isolated store and hands them to the private instance at once.
    func setValues(_ changes: [String: String]) {
        guard !isEnded else { return }
        var values = values
        values.merge(changes) { _, new in new }
        targets.publish(values, services: services)
        targets.save(values, defaults: defaults)
    }

    /// Replaces every value of the isolated store with `values` (a mode's own saved version, e.g.
    /// the screen saver's choices) and hands them to the private instance at once.
    func replaceValues(_ values: [String: String]) {
        guard !isEnded else { return }
        targets.save(values, defaults: defaults)
        services.setUserProperties(values, wallpaper: runtimeKey, replacing: true)
    }

    /// Shows or hides a layer in this version only.
    func setLayerVisible(_ visible: Bool, objectID: Int) {
        setValues([sceneObjectVisibilityKey(objectID: objectID): visible ? "true" : "false"])
    }

    /// Drops the isolated store; the private instance stops with the view that holds it. Later
    /// calls do nothing.
    func end() {
        guard !isEnded else { return }
        isEnded = true
        for family in WallpaperSettingsIdentity.Family.allCases {
            defaults.removeObject(forKey: targets.identity.key(family, scope: scope))
        }
        services.setUserProperties([:], wallpaper: runtimeKey, replacing: true)
    }
}
