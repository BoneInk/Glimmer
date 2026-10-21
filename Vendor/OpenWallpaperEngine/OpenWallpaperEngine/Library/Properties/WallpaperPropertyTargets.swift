import Foundation

/// The user-property stores an edit in the sidebar or the inspector goes to: the selected
/// displays' (`WallpaperViewModel.editedPropertyScopes`), or the shared store while properties
/// are synced. The first scope is the one shown.
struct WallpaperPropertyTargets {
    let directory: URL
    let identity: WallpaperSettingsIdentity
    let scopes: [WallpaperPropertyScope]

    init(wallpaper: WEWallpaper, scopes: [WallpaperPropertyScope]) {
        // A Workshop preset item has its own running store, apart from its base's.
        directory = wallpaper.settingsDirectory
        identity = WallpaperSettingsIdentity.resolve(wallpaper)
        self.scopes = scopes.isEmpty ? [.shared] : scopes
    }

    private init(directory: URL, identity: WallpaperSettingsIdentity, scopes: [WallpaperPropertyScope]) {
        self.directory = directory
        self.identity = identity
        self.scopes = scopes.isEmpty ? [.shared] : scopes
    }

    /// The same wallpaper's stores `scopes` (the Wallpaper Editor's draft beside the shared store).
    func scoped(_ scopes: [WallpaperPropertyScope]) -> WallpaperPropertyTargets {
        WallpaperPropertyTargets(directory: directory, identity: identity, scopes: scopes)
    }

    /// The shown scope's saved values (the shared ones for a display that has none yet).
    var storedValues: [String: String] {
        identity.stored(.userProperties, scope: scopes[0]) as? [String: String] ?? [:]
    }

    /// The keys of the running stores (`SceneUserPropertyService`) the scopes are read from.
    var runtimeKeys: [String] { scopes.map { $0.runtimeKey(directory: directory) } }

    /// Hands `values` to the running wallpapers at once: only what differs from each running store,
    /// where a key the store lacks stands for its default (`defaults`, the value the wallpaper
    /// takes without it). Showing the properties with nothing changed changes nothing, so opening
    /// the panel never rebuilds a wallpaper.
    func publish(_ values: [String: String], defaults: [String: String] = [:],
                 services: WallpaperServices = .shared) {
        for key in runtimeKeys {
            let changed = Self.changes(values, from: services.userProperties(wallpaper: key), defaults: defaults)
            guard !changed.isEmpty else { continue }
            services.setUserProperties(changed, wallpaper: key, replacing: false)
        }
    }

    /// The entries of `values` that change `running`, a missing key being its default.
    static func changes(_ values: [String: String], from running: [String: String],
                        defaults: [String: String]) -> [String: String] {
        values.filter { key, value in (running[key] ?? defaults[key]) != value }
    }

    /// Saves `values` as every scope's, marked as set by the user, and lets the displays regroup
    /// by their properties (`Notification.Name.wallpaperPropertiesDidSave`).
    func save(_ values: [String: String], defaults: UserDefaults = .app) {
        for scope in scopes {
            defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
            defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
        }
        postSaved()
    }

    /// Lets the displays regroup, unless only isolated stores changed, which no display runs
    /// (`WallpaperPropertyScope.isolated`).
    private func postSaved() {
        guard scopes.contains(where: { !$0.isIsolated }) else { return }
        NotificationCenter.default.post(name: .wallpaperPropertiesDidSave, object: directory.path)
    }

    /// WE's Reset (`WallpaperPropertyReset`): each scope's properties go back to `defaultValues`,
    /// and its Scene Edit / Export edits are dropped. Returns the shown scope's new values.
    @discardableResult
    func reset(to defaultValues: [String: String], defaults: UserDefaults = .app,
               publish: (String, [String: String]) -> Void = Self.publishReplacing) -> [String: String] {
        rewrite(defaults: defaults, publish: publish) { WallpaperPropertyReset.values(resetting: $0, to: defaultValues) }
    }

    /// Applies a preset ("Your Presets"): each scope's values become `values`, Scene Edit / Export
    /// edits included, and a property the preset doesn't name falls back to its default. The keys
    /// in `keeping` (user shortcuts, which presets leave out) keep each scope's own value. Returns
    /// the shown scope's new values.
    @discardableResult
    func apply(preset values: [String: String], keeping: Set<String> = [], defaults: UserDefaults = .app,
               publish: (String, [String: String]) -> Void = Self.publishReplacing) -> [String: String] {
        rewrite(defaults: defaults, publish: publish) { stored in
            values.filter { !keeping.contains($0.key) }.merging(stored.filter { keeping.contains($0.key) }) { _, own in own }
        }
    }

    /// Scene Edit / Export's Reset: each scope's inspector edits are dropped, its other
    /// properties kept. Returns the shown scope's new values.
    @discardableResult
    func removeSceneInspectorEdits(defaults: UserDefaults = .app,
                                   publish: (String, [String: String]) -> Void = Self.publishReplacing) -> [String: String] {
        rewrite(defaults: defaults, publish: publish, WallpaperPropertyReset.values(removingSceneInspectorEditsFrom:))
    }

    /// Hands a store's whole set of values to its running wallpaper: keys missing from them are
    /// dropped there too, and the wallpaper applies the change live or rebuilds what it needs
    /// (`SceneContentLoader.impact(of:)`).
    static func publishReplacing(_ runtimeKey: String, _ values: [String: String]) {
        WallpaperServices.shared.setUserProperties(values, wallpaper: runtimeKey, replacing: true)
    }

    /// Replaces every scope's saved values with `transform` of them (a display without its own
    /// yet starts from the shared ones), saves them as set by the user, so a load doesn't
    /// re-derive what the transform kept, and publishes them.
    private func rewrite(defaults: UserDefaults, publish: (String, [String: String]) -> Void,
                         _ transform: ([String: String]) -> [String: String]) -> [String: String] {
        var shown: [String: String]?
        for scope in scopes {
            let values = transform(identity.stored(.userProperties, scope: scope, defaults: defaults) as? [String: String] ?? [:])
            defaults.set(values, forKey: identity.key(.userProperties, scope: scope))
            defaults.set(true, forKey: identity.key(.explicitUserProperties, scope: scope))
            publish(scope.runtimeKey(directory: directory), values)
            if shown == nil { shown = values }
        }
        postSaved()
        return shown ?? [:]
    }
}
