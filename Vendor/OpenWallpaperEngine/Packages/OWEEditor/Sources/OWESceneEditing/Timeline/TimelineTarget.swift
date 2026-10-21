import Foundation

/// The property a timeline animates: a layer's own field (`objects[i].origin`) or a constant of
/// one of its effects' materials (`effects[e].passes[p].constantshadervalues.<key>`), the two
/// places WE's library animates (docs/timeline-plan.md §1.1).
public struct TimelineTarget: Codable, Hashable, Comparable, Sendable {
    /// The layer's `id` (its index without one), as the overlay keys layers.
    public var layer: Int
    /// The effect's index in the layer's `effects`; nil for the layer's own field.
    public var effect: Int?
    /// The material pass of the effect.
    public var pass: Int?
    /// The field or constant name, as scene.json spells it.
    public var key: String

    public init(layer: Int, effect: Int? = nil, pass: Int? = nil, key: String) {
        self.layer = layer
        self.effect = effect
        self.pass = effect == nil ? nil : (pass ?? 0)
        self.key = key
    }

    /// A layer's own field (`origin`, `alpha`, …).
    public static func field(_ key: String, of layer: Int) -> TimelineTarget {
        TimelineTarget(layer: layer, key: key)
    }

    /// A constant of an effect's material pass.
    public static func constant(_ key: String, effect: Int, pass: Int = 0, of layer: Int) -> TimelineTarget {
        TimelineTarget(layer: layer, effect: effect, pass: pass, key: key)
    }

    /// Layer, then its own fields in `fieldOrder`, then its effects' constants.
    public static func < (lhs: TimelineTarget, rhs: TimelineTarget) -> Bool {
        if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
        switch (lhs.effect, rhs.effect) {
        case (nil, nil):
            let left = fieldOrder.firstIndex(of: lhs.key) ?? fieldOrder.count
            let right = fieldOrder.firstIndex(of: rhs.key) ?? fieldOrder.count
            return left != right ? left < right : lhs.key < rhs.key
        case (nil, _?): return true
        case (_?, nil): return false
        case let (left?, right?):
            if left != right { return left < right }
            if lhs.pass != rhs.pass { return (lhs.pass ?? 0) < (rhs.pass ?? 0) }
            return lhs.key < rhs.key
        }
    }

    /// The layer fields WE's setter writes from a timeline (numbers and vectors; `visible`, a
    /// bool, never is), with their component counts, in the order the timeline lists them.
    public static let animatableFields: [String: Int] = [
        "origin": 3, "scale": 3, "angles": 3, "alpha": 1, "color": 3, "brightness": 1, "size": 2,
        "parallaxDepth": 2, "volume": 1,
    ]

    static let fieldOrder = ["origin", "scale", "angles", "size", "alpha", "color", "brightness", "parallaxDepth", "volume"]
}

/// One keyframe of one channel of a track: what the timeline selects, moves and copies. A
/// channel's frames are unique, so the frame names the keyframe.
public struct TimelineKeyframeRef: Hashable, Sendable {
    public var target: TimelineTarget
    public var channel: Int
    public var frame: Int

    public init(target: TimelineTarget, channel: Int, frame: Int) {
        self.target = target
        self.channel = channel
        self.frame = frame
    }
}
