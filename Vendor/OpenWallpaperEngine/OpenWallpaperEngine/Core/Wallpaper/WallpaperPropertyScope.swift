import Foundation

extension Notification.Name {
    /// A wallpaper's user properties were saved (the sidebar or the inspector): displays regroup
    /// by their properties (`WallpaperViewModel.refreshInstanceKeys`).
    static let wallpaperPropertiesDidSave = Notification.Name("WallpaperPropertiesDidSave")
}

/// Whose user properties a wallpaper runs with: one store every display shares ("Sync properties
/// across displays"), or each display's own.
///
/// WE keeps a wallpaper's properties per display (`currentSelection.properties[monitor.location]`
/// in its `ui/dist/scripts/scripts.js`), so the same wallpaper on two displays has independent
/// properties under its default "Wallpaper per display" layout; its "Clone single wallpaper"
/// layout shows one wallpaper, with one set of properties, on every display. The sync setting is
/// that choice for properties alone.
///
/// `isolated` is a private copy one of Scene Edit / Export's modes edits (the iPhone & iPad
/// Export mode's, named by the mode), seeded from the edited store when the mode opens and dropped
/// when it closes (`IsolatedSceneEditSession`): what it changes runs only in that mode's private
/// instance and its offscreen render, never on a display. `editorDraft` is the Wallpaper Editor's
/// (`WallpaperEditorDraft`): its canvas runs the draft's properties and edit overlay alone until
/// File › Save.
enum WallpaperPropertyScope: Hashable, CustomStringConvertible {
    case shared
    case display(String)
    case isolated(String)

    /// The Wallpaper Editor's draft of a wallpaper: what its canvas runs.
    static let editorDraft = WallpaperPropertyScope.isolated("wallpaper-editor")

    /// No display runs this store (`isolated`).
    var isIsolated: Bool {
        if case .isolated = self { return true }
        return false
    }

    /// Appended to the wallpaper's settings keys (`WallpaperSettingsIdentity.key(_:scope:)`).
    var settingsSuffix: String {
        switch self {
        case .shared: return ""
        case .display(let id): return ".display.\(id)"
        case .isolated(let id): return ".isolated.\(id)"
        }
    }

    /// The key of this scope's properties in the running store (`SceneUserPropertyService`), for
    /// the wallpaper in `directory`: its path for the shared store, as before scopes existed.
    func runtimeKey(directory: URL) -> String {
        switch self {
        case .shared: return directory.path
        case .display(let id): return directory.path + "#display=" + id
        case .isolated(let id): return directory.path + "#isolated=" + id
        }
    }

    var description: String {
        switch self {
        case .shared: return "shared"
        case .display(let id): return "display \(id)"
        case .isolated(let id): return "isolated \(id)"
        }
    }
}

extension WallpaperSettingsIdentity {
    /// `family`'s key for `scope`.
    func key(_ family: Family, scope: WallpaperPropertyScope) -> String { key(family) + scope.settingsSuffix }

    /// `scope`'s stored values of `family`, falling back to the shared ones for a display whose own
    /// were never saved: a display starts from the properties the wallpaper had before.
    func stored(_ family: Family, scope: WallpaperPropertyScope, defaults: UserDefaults = .app) -> Any? {
        defaults.object(forKey: key(family, scope: scope)) ?? defaults.object(forKey: key(family))
    }

    /// The values the user set for `scope`, which a wallpaper starts with: its own when the user
    /// set them, else the shared ones the user set (a display that never had its own, or whose own
    /// were seeded before the shared ones were set), else none (project.json's defaults apply).
    /// Every load reads them here, so a scene, its scripts, its text and a web page all start with
    /// what the sidebar shows.
    func userSetValues(scope: WallpaperPropertyScope, defaults: UserDefaults = .app) -> [String: String] {
        for candidate in [scope, .shared] where defaults.bool(forKey: key(.explicitUserProperties, scope: candidate)) {
            return defaults.dictionary(forKey: key(.userProperties, scope: candidate)) as? [String: String] ?? [:]
        }
        return [:]
    }

    /// Saves the shared values under `scope`'s own keys when it has none yet, so a display's store
    /// starts from the wallpaper's properties and is read and written under its own key from then on.
    func seed(_ scope: WallpaperPropertyScope, defaults: UserDefaults = .app) {
        guard scope != .shared else { return }
        for family in Family.allCases where defaults.object(forKey: key(family, scope: scope)) == nil {
            if let shared = defaults.object(forKey: key(family)) { defaults.set(shared, forKey: key(family, scope: scope)) }
        }
    }

    /// Saves `scope`'s own values as the shared ones, so turning "Sync properties across displays"
    /// on keeps what that display ran instead of the shared store left from before displays had
    /// their own (or, never saved, project.json's defaults).
    func share(_ scope: WallpaperPropertyScope, defaults: UserDefaults = .app) {
        guard scope != .shared else { return }
        for family in Family.allCases {
            if let own = defaults.object(forKey: key(family, scope: scope)) { defaults.set(own, forKey: key(family)) }
        }
    }
}
