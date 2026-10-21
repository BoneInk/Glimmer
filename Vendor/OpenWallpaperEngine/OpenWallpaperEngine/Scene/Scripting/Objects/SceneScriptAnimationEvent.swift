import Foundation

extension SceneScriptEvent.Kind {
    /// `animationEvent(event, value)` on the scripts of the animation's owner
    /// (`objects-animations.js`); payload: `["slot": animationSlot, "name": String, "frame": Double]`.
    static let animationEvent = Self(rawValue: "animationEvent")
}

extension SceneScriptEvent {
    /// A timeline event the clock crossed (docs/timeline-plan.md §3.3), for the animation in
    /// `animationSlot` of the object model's animation buffer. Post it after advancing the clocks
    /// and before `__rt.frame` drains the inbox; it reaches scripts after the frame's media events
    /// and before timers and `update` (§1.9 P1). Events are discrete: a full inbox never merges them.
    static func animationEvent(animationSlot: Int, name: String, frame: Double) -> SceneScriptEvent {
        SceneScriptEvent(kind: .animationEvent, payload: ["slot": animationSlot, "name": name, "frame": frame],
                         coalescing: .keep)
    }
}

extension SceneScriptEvent.Kind {
    /// A puppet's or model's animation layers this frame (`objects-layers.js`): each clip event
    /// crossed, as `animationEvent`, then the layers' ended callbacks; payload:
    /// `["slot": objectSlot, "events": [String]]` (each event's name, as the `.mdl` stores it).
    static let rigAnimation = Self(rawValue: "rigAnimation")
}

extension SceneScriptEvent {
    /// WE's object update (0x1401fdf90 for images, 0x14021c480 for models) sends each clip event
    /// its layers crossed to the object's scripts as callback 6, `animationEvent` (0x14020022e,
    /// 0x14021cdbf → 0x140177ad0: the scripts whose object is the updated one), passing only the
    /// event's name (the record's string at +8, 0x1401aa1c0), and runs the ended callbacks right
    /// after (0x140200290…0x1402002f1). All of it comes before the cursor pass and the scene's
    /// update (media, timelines, the scripts' `update`), so this is handled first.
    static func rigAnimation(objectSlot: Int, events: [String]) -> SceneScriptEvent {
        SceneScriptEvent(kind: .rigAnimation, payload: ["slot": objectSlot, "events": events], target: objectSlot,
                         coalescing: .keep)
    }
}
