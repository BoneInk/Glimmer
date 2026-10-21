import Foundation

/// Where a bindable scene value comes from. Resolved to a `ShaderValue` by `SceneValueResolver`.
///
/// WE JSON forms and how `init?(json:)` maps them:
/// - `0.5`, `true`, `"1 0.5 0"` → `.literal`
/// - `{"value": v, "user": "name"}` → `.user(name, nil, fallback: v)`
/// - `{"value": v, "user": {"name": n, "condition": c}}` → `.user(n, c, fallback: v)`
/// - `{"value": v, "script": s, "scriptproperties": {…}}` → `.script(s, props, fallback: v)`
/// - `{"value": v, "animation": {…}}` → `.animation(site: nil, fallback: v)`
///
/// When several keys are present they nest: `script` wraps `animation`, which wraps `user`,
/// which wraps the literal `value`. That is WE's precedence (docs/timeline-plan.md §2.6): the
/// timeline's setter runs every frame over the static and user-bound value, and a script's return
/// wins for its frame. A missing `value` falls back to 0.
///
/// The timeline itself lives in the wallpaper instance's `SceneAnimationSet`; the source only
/// names its site, which the loader binds (`bindingAnimation(to:)`) where it knows the owner.
indirect enum SceneValueSource: Equatable {
    case literal(ShaderValue)
    case user(name: String, condition: String?, fallback: SceneValueSource)
    case script(source: String, properties: SceneScriptProperties, fallback: SceneValueSource)
    /// The value of the timeline at `site` this frame; `fallback` while the site is unbound or
    /// the instance has no such timeline (one that didn't load, logged by the set).
    case animation(site: SceneAnimationSite?, fallback: SceneValueSource)

    /// True when the value can change after load (so it must be re-resolved every frame).
    var isDynamic: Bool {
        if case .literal = self { return false }
        return true
    }

    /// Parses JSONSerialization output (NSNumber, Bool, String or Dictionary). Logs and returns
    /// nil for anything it can't represent.
    init?(json: Any) {
        if let dictionary = json as? [String: Any] {
            self.init(dictionary: dictionary)
            return
        }
        guard let value = ShaderValue(json: json) else {
            OWELog.error(.scene, "SceneValueSource: unparseable value \(json)")
            return nil
        }
        self = .literal(value)
    }

    private init?(dictionary: [String: Any]) {
        let known: Set<String> = ["value", "user", "script", "scriptproperties", "animation"]
        guard !Set(dictionary.keys).isDisjoint(with: known) else {
            OWELog.error(.scene, "SceneValueSource: object with none of \(known.sorted()): \(dictionary.keys.sorted())")
            return nil
        }

        var source: SceneValueSource
        if let raw = dictionary["value"] {
            guard let value = ShaderValue(json: raw) else {
                OWELog.error(.scene, "SceneValueSource: unparseable 'value' \(raw)")
                return nil
            }
            source = .literal(value)
        } else {
            source = .literal(.zero)
        }

        // WE's editor writes `"user": null` on values that aren't bound; that means no binding.
        if let raw = dictionary["user"], !(raw is NSNull) {
            if let name = raw as? String {
                source = .user(name: name, condition: nil, fallback: source)
            } else if let user = raw as? [String: Any], let name = user["name"] as? String {
                let condition: String?
                switch user["condition"] {
                case nil: condition = nil
                case let string as String: condition = string
                case let number as NSNumber: condition = number.stringValue
                case let other?:
                    OWELog.error(.scene, "SceneValueSource: unsupported user condition \(other)")
                    return nil
                }
                source = .user(name: name, condition: condition, fallback: source)
            } else {
                OWELog.error(.scene, "SceneValueSource: unsupported 'user' binding \(raw)")
                return nil
            }
        }

        // `"animation": null` and `"script": null` likewise mean none (e.g. 2048761036).
        if let raw = dictionary["animation"], !(raw is NSNull) {
            guard raw is [String: Any] else {
                OWELog.error(.scene, "SceneValueSource: 'animation' is not an object")
                return nil
            }
            source = .animation(site: nil, fallback: source)
        }

        if let raw = dictionary["script"], !(raw is NSNull) {
            guard let script = raw as? String else {
                OWELog.error(.scene, "SceneValueSource: 'script' is not a string")
                return nil
            }
            let properties = SceneScriptProperties(json: Self.scriptPropertyValues(dictionary["scriptproperties"]))
            source = .script(source: script, properties: properties, fallback: source)
        }
        self = source
    }

    /// `scriptproperties` as name → value. Older WE editors saved it as an array of
    /// `{key, value, …}` rows (e.g. 2176097362); newer ones as an object.
    static func scriptPropertyValues(_ raw: Any?) -> [String: Any] {
        if let object = raw as? [String: Any] { return object }
        guard let rows = raw as? [[String: Any]] else { return [:] }
        var values: [String: Any] = [:]
        for row in rows {
            guard let key = row["key"] as? String, let value = row["value"] else { continue }
            values[key] = value
        }
        return values
    }

    /// This source with its timeline bound to `site` (an animated constant's owner and key).
    func bindingAnimation(to site: SceneAnimationSite) -> SceneValueSource {
        switch self {
        case .literal, .user: return self
        case let .script(source, properties, fallback):
            return .script(source: source, properties: properties, fallback: fallback.bindingAnimation(to: site))
        case .animation(_, let fallback): return .animation(site: site, fallback: fallback)
        }
    }

    /// The timeline site this source reads, under a script; nil when there is none or it's unbound.
    var animationSite: SceneAnimationSite? {
        switch self {
        case .literal, .user: return nil
        case .script(_, _, let fallback): return fallback.animationSite
        case .animation(let site, _): return site
        }
    }

    /// The user property this value is bound to, under any script or timeline; nil when unbound.
    var boundUserProperty: String? {
        switch self {
        case .literal: return nil
        case .user(let name, _, _): return name
        case .script(_, _, let fallback), .animation(_, let fallback): return fallback.boundUserProperty
        }
    }

    /// This source with its static and user-bound part replaced by `base`, keeping a script and a
    /// timeline over it; `base` itself when there is neither.
    func replacingBase(with base: SceneValueSource) -> SceneValueSource {
        switch self {
        case .literal, .user: return base
        case let .script(source, properties, fallback):
            return .script(source: source, properties: properties, fallback: fallback.replacingBase(with: base))
        case .animation(let site, let fallback): return .animation(site: site, fallback: fallback.replacingBase(with: base))
        }
    }
}
