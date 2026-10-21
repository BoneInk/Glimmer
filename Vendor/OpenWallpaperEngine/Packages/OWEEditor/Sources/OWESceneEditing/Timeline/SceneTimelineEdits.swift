import Foundation

/// The editor's timeline edits in the overlay (`SceneEditOverlay.timelines`): per animated
/// property, the clip that replaces the authored `animation` (or adds one), or that the authored
/// one was removed. Clips are stored in WE's own `animation` format.
public struct SceneTimelineEdits: Codable, Hashable, Sendable {
    public struct Track: Codable, Hashable, Sendable {
        public var target: TimelineTarget
        /// The property's timeline; nil removes the authored one.
        public var clip: TimelineClip?

        public init(target: TimelineTarget, clip: TimelineClip?) {
            self.target = target
            self.clip = clip
        }
    }

    /// Sorted by target, so the same edits always write the same bytes.
    public private(set) var tracks: [Track] = []

    public init(tracks: [Track] = []) {
        self.tracks = tracks.sorted { $0.target < $1.target }
    }

    public var isEmpty: Bool { tracks.isEmpty }

    /// The edit of `target`'s timeline, if the editor changed it.
    public func track(_ target: TimelineTarget) -> Track? {
        tracks.first { $0.target == target }
    }

    /// Records `target`'s timeline: a clip, or nil for none.
    public mutating func set(_ clip: TimelineClip?, for target: TimelineTarget) {
        tracks.removeAll { $0.target == target }
        tracks.append(Track(target: target, clip: clip))
        tracks.sort { $0.target < $1.target }
    }

    /// Forgets the edit of `target`: the authored timeline again.
    public mutating func drop(_ target: TimelineTarget) {
        tracks.removeAll { $0.target == target }
    }

    public func touches(layer: Int) -> Bool {
        tracks.contains { $0.target.layer == layer }
    }

    // MARK: Applying

    /// Writes the timelines into a decoded scene.json's `objects`: an animated property becomes
    /// `{"value": …, "animation": …}` (its static value kept, so `relative` and a removed
    /// timeline still have it); a removed timeline leaves its value. A layer or effect the scene
    /// no longer has is skipped.
    public func apply(to objects: inout [[String: Any]]) {
        guard !tracks.isEmpty else { return }
        var positions: [Int: Int] = [:]
        for index in objects.indices {
            let id = SceneObjects.objectID(objects[index], index: index)
            if positions[id] == nil { positions[id] = index }
        }
        for track in tracks {
            guard let index = positions[track.target.layer] else { continue }
            let target = track.target
            if let effectIndex = target.effect {
                guard var effects = objects[index]["effects"] as? [[String: Any]], effects.indices.contains(effectIndex) else { continue }
                var passes = effects[effectIndex]["passes"] as? [[String: Any]] ?? []
                let pass = target.pass ?? 0
                guard pass >= 0 else { continue }
                while passes.count <= pass { passes.append([:]) }
                // WE's scene.json keeps a pass's values in `constantshadervalues`; older files in `constants`.
                let block = MaterialPassDocument.constantsKey(of: passes[pass])
                var constants = passes[pass][block] as? [String: Any] ?? [:]
                let key = constants.keys.first { $0.caseInsensitiveCompare(target.key) == .orderedSame } ?? target.key
                constants[key] = Self.animated(constants[key], clip: track.clip)
                if constants[key] == nil { constants.removeValue(forKey: key) }
                passes[pass][block] = constants
                effects[effectIndex]["passes"] = passes
                objects[index]["effects"] = effects
            } else {
                objects[index][target.key] = Self.animated(objects[index][target.key], clip: track.clip,
                                                           fallback: Self.defaultValue(of: target.key))
            }
        }
    }

    /// The bound value with `clip` as its `animation`, or without one when `clip` is nil.
    static func animated(_ existing: Any?, clip: TimelineClip?, fallback: SceneJSONValue? = nil) -> Any? {
        var holder: [String: Any]
        if let object = existing as? [String: Any],
           object["value"] != nil || object["animation"] != nil || object["script"] != nil || object["user"] != nil {
            holder = object
        } else if let existing {
            holder = ["value": existing]
        } else {
            holder = [:]
        }
        guard let clip else {
            holder.removeValue(forKey: "animation")
            if holder.count == 1, let value = holder["value"] { return value }
            return holder.isEmpty ? existing : holder
        }
        if holder["value"] == nil {
            holder["value"] = (fallback ?? Self.firstValues(of: clip)).any
        }
        holder["animation"] = clip.json.any
        return holder
    }

    /// WE's value of a field a layer doesn't write.
    static func defaultValue(of key: String) -> SceneJSONValue? {
        defaults[key]
    }

    /// The animatable fields' defaults, as `SceneEditSession.defaults` has them.
    static let defaults: [String: SceneJSONValue] = [
        "alpha": .number(1), "origin": .string("0 0 0"), "scale": .string("1 1 1"), "angles": .string("0 0 0"),
        "color": .string("1 1 1"), "brightness": .number(1),
    ]

    /// The clip's first keyframes as a value: a number for one channel, else a vector string.
    static func firstValues(of clip: TimelineClip) -> SceneJSONValue {
        let values = clip.channels.map { $0.first?.value ?? 0 }
        return values.count == 1 ? .number(values[0]) : SceneVector.value(values)
    }
}
