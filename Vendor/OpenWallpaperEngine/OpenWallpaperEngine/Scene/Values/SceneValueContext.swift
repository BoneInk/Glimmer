import Foundation


/// What `SceneValueResolver` needs from the running scene to resolve bound values.
protocol SceneValueContext {
    /// The user property's current value as WE stores it ("1", "0.5 0.2 1", "true", a combo value),
    /// or nil when the wallpaper has no such property.
    func userProperty(_ name: String) -> String?
    /// The timeline at `site` as the wallpaper instance's `SceneAnimationSet` sampled it this
    /// frame, one component per channel; nil when nothing animates it.
    func animationValue(_ site: SceneAnimationSite) -> [Float]?
    /// The binding revision of the object being drawn (`SceneBindingRevisions`): values bound to
    /// user properties alone are kept while it stays. Nil outside the renderer: nothing is kept.
    var bindingRevision: UInt64? { get }
    /// Whether property `name` (or a component of it) follows the music, so its value changes
    /// every frame.
    func isMusicSynced(_ name: String) -> Bool
}

extension SceneValueContext {
    func animationValue(_ site: SceneAnimationSite) -> [Float]? { nil }
    var bindingRevision: UInt64? { nil }
    func isMusicSynced(_ name: String) -> Bool { false }
}

/// `SceneValueContext` over the app's user property store.
struct LiveSceneValueContext: SceneValueContext {
    let engine: WallpaperServices
    /// The rendering instance's timelines; nil outside a frame (values resolve without them).
    let animations: SceneAnimationSet?
    /// The wallpaper whose user properties to read; nil reads the wallpaper being rendered.
    let wallpaper: String?
    /// The drawn object's binding revision; the renderer sets it per object.
    var bindingRevision: UInt64?

    init(engine: WallpaperServices = .shared, animations: SceneAnimationSet? = nil, wallpaper: String? = nil) {
        self.engine = engine
        self.animations = animations
        self.wallpaper = wallpaper
    }

    func animationValue(_ site: SceneAnimationSite) -> [Float]? {
        animations?.drawnValue(of: site)
    }

    /// A scalar syncs under `<name>`, each vector component under `<name>_<i>` (`musicSynced`).
    func isMusicSynced(_ name: String) -> Bool {
        engine.isMusicSynced(name) || (0..<4).contains { engine.isMusicSynced("\(name)_\($0)") }
    }

    /// Reads outside a frame (`wallpaper` set) are the stored value; reads while rendering follow
    /// the music like the engine's numeric reads do.
    func userProperty(_ name: String) -> String? {
        if let wallpaper { return engine.userPropertyString(name, wallpaper: wallpaper) }
        guard let raw = engine.userPropertyString(name) else { return nil }
        return Self.musicSynced(raw, name: name, isSynced: engine.isMusicSynced,
                                modulate: { engine.userPropertyValue($0, fallback: $1) })
    }

    /// Applies music sync to a numeric property string. A scalar syncs under `<name>`, each vector
    /// component `i` under `<name>_<i>`; `modulate(key, base)` is the engine's numeric path
    /// (base + level × `<key>_musicAmount`). Non-numeric and unsynced values pass through.
    static func musicSynced(_ raw: String, name: String, isSynced: (String) -> Bool,
                            modulate: (String, Float) -> Float) -> String {
        guard let value = ShaderValue(string: raw) else { return raw }
        let components = value.components
        if components.count == 1 {
            guard isSynced(name) else { return raw }
            return String(modulate(name, components[0]))
        }
        var changed = false
        let modulated = components.enumerated().map { index, component -> Float in
            let key = "\(name)_\(index)"
            guard isSynced(key) else { return component }
            changed = true
            return modulate(key, component)
        }
        return changed ? modulated.map { String($0) }.joined(separator: " ") : raw
    }
}
