import Foundation

/// Something that happened outside the render thread and reaches scripts at the start of the next
/// frame, in arrival order (docs/scenescript-plan.md §4.4 step 2).
struct SceneScriptEvent {
    /// Event kinds. The runtime handles the three below; other packages add kinds in their own files
    /// (`extension SceneScriptEvent.Kind { static let mediaPlayback = … }`) and register a JS handler
    /// for them with `__rt.addEventHandler(kind, handler)`.
    struct Kind: RawRepresentable, Hashable {
        let rawValue: String
        init(rawValue: String) { self.rawValue = rawValue }

        /// `applyUserProperties(changed)` on every script; payload: only the changed properties.
        static let userProperties = Kind(rawValue: "userProperties")
        /// `applyGeneralSettings(changed)`; payload: only the changed settings (`language`).
        static let generalSettings = Kind(rawValue: "generalSettings")
        /// `resizeScreen(size)`; payload: `["x": width, "y": height]` in pixels. Never sent at startup.
        static let resize = Kind(rawValue: "resize")
    }

    /// What the inbox may do with an undrained event once it is full (frames stopped: paused,
    /// occluded, display asleep). Never applied while the runtime keeps up.
    enum Coalescing {
        /// A whole state (media parts, a resize, a cursor move): only the newest event of the same
        /// kind and target is kept.
        case latest
        /// A partial dictionary of changes (user properties, general settings): the events of the
        /// kind become one, later keys winning, so no change is lost.
        case merge
        /// A discrete event that must not be merged (a click). Dropped oldest first, and only when
        /// coalescing everything else did not make room.
        case keep
    }

    var kind: Kind
    /// A JavaScript-convertible value: dictionaries, arrays, strings, numbers, booleans, NSNull.
    var payload: Any
    /// The object slot the event is for (cursor events), or nil for every script.
    var target: Int?
    var coalescing: Coalescing

    /// `coalescing` defaults to `.merge` for user properties and general settings and to
    /// `.latest` for every other kind: events are states unless their poster says otherwise.
    init(kind: Kind, payload: Any, target: Int? = nil, coalescing: Coalescing? = nil) {
        self.kind = kind
        self.payload = payload
        self.target = target
        self.coalescing = coalescing ?? (kind == .userProperties || kind == .generalSettings ? .merge : .latest)
    }

    /// The object `__rt.frame` receives.
    var javaScriptObject: [String: Any] {
        var object: [String: Any] = ["kind": kind.rawValue, "payload": payload]
        if let target { object["target"] = target }
        return object
    }
}
