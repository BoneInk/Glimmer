import Foundation

/// What scene.json authors that a timeline can animate: each layer's animatable fields and its
/// effects' numeric constants, with their authored values and timelines.
public struct TimelineSceneIndex: Sendable {
    public struct Property: Hashable, Sendable {
        public var target: TimelineTarget
        /// The authored bound value (`{"value", "animation", …}`) or plain value; nil when absent.
        public var authored: SceneJSONValue?
        /// How many components the value has (1–4): the channels a new timeline gets.
        public var channelCount: Int

        /// The authored timeline, if it can be read (WE plays none without numeric fps and length).
        public var authoredClip: TimelineClip? {
            authored?["animation"].flatMap(TimelineClip.init(json:))
        }

        /// The authored static value: a bound value's `value`, else the value itself.
        public var staticValue: SceneJSONValue? { SceneFieldBinding.literal(of: authored) }

        /// A user property sets it: WE's editor offers no keyframes for it.
        public var isUserBound: Bool {
            if case .userProperty = SceneFieldBinding(authored) { return true }
            return false
        }
    }

    /// Effect constants by layer, in effect order.
    private var constants: [Int: [Property]] = [:]
    /// Animated fields outside `TimelineTarget.animatableFields`, by layer.
    private var otherAnimatedFields: [Int: [Property]] = [:]
    private var fields: [Int: [String: SceneJSONValue]] = [:]
    /// scene.json's timelines, read once.
    private var authoredClips: [TimelineTarget: TimelineClip] = [:]
    /// Layer ids in scene order.
    public private(set) var layers: [Int] = []

    public static let empty = TimelineSceneIndex()

    private init() {}

    public init(sceneData: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: sceneData) as? [String: Any],
              let objects = root["objects"] as? [[String: Any]] else { throw SceneEditOverlayError.notAScene }
        for (index, object) in objects.enumerated() {
            let id = SceneObjects.objectID(object, index: index)
            guard fields[id] == nil else { continue }
            layers.append(id)
            var layerFields: [String: SceneJSONValue] = [:]
            for (key, value) in object where key != "effects" {
                if let value = SceneJSONValue(any: value) { layerFields[key] = value }
            }
            fields[id] = layerFields
            otherAnimatedFields[id] = layerFields.keys.sorted().compactMap { key in
                guard TimelineTarget.animatableFields[key] == nil, let value = layerFields[key],
                      let clip = value["animation"].flatMap(TimelineClip.init(json:)) else { return nil }
                return Property(target: .field(key, of: id), authored: value, channelCount: clip.channels.count)
            }
            var layerConstants: [Property] = []
            for (effectIndex, effect) in (object["effects"] as? [[String: Any]] ?? []).enumerated() {
                for (passIndex, pass) in (effect["passes"] as? [[String: Any]] ?? []).enumerated() {
                    guard let block = MaterialPassDocument.constants(of: pass) else { continue }
                    for key in block.keys.sorted() {
                        guard let value = SceneJSONValue(any: block[key]),
                              let count = Self.channelCount(of: value) else { continue }
                        layerConstants.append(Property(target: .constant(key, effect: effectIndex, pass: passIndex, of: id),
                                                       authored: value, channelCount: count))
                    }
                }
            }
            constants[id] = layerConstants
            for property in properties(of: id) {
                if let clip = property.authoredClip { authoredClips[property.target] = clip }
            }
        }
    }

    /// scene.json's timeline of the property, if it has one WE plays.
    public func authoredClip(_ target: TimelineTarget) -> TimelineClip? {
        authoredClips[target]
    }

    /// The components of a numeric value (a bound value's `value`, or its timeline's channels); nil
    /// for anything else (a bool, a texture name).
    static func channelCount(of value: SceneJSONValue) -> Int? {
        if let clip = value["animation"].flatMap(TimelineClip.init(json:)), !clip.channels.isEmpty {
            return clip.channels.count
        }
        switch SceneFieldBinding.literal(of: value) {
        case .number?: return 1
        case .string(let text)?:
            let components = SceneVector.components(.string(text))
            let tokens = SceneVector.tokens(text)
            guard !components.isEmpty, components.count == tokens.count else { return nil }
            return min(components.count, 4)
        default: return nil
        }
    }

    // MARK: Reading

    /// Everything a timeline can animate on layer `id`: its animatable fields (every one, authored
    /// or not), animated fields of other kinds, then its effects' constants.
    public func properties(of id: Int) -> [Property] {
        guard let layerFields = fields[id] else { return [] }
        let own = TimelineTarget.fieldOrder.compactMap { key -> Property? in
            guard let count = TimelineTarget.animatableFields[key] else { return nil }
            return Property(target: .field(key, of: id), authored: layerFields[key], channelCount: count)
        }
        return own + (otherAnimatedFields[id] ?? []) + (constants[id] ?? [])
    }

    public func property(_ target: TimelineTarget) -> Property? {
        guard let layerFields = fields[target.layer] else { return nil }
        if target.effect == nil {
            if let count = TimelineTarget.animatableFields[target.key] {
                return Property(target: target, authored: layerFields[target.key], channelCount: count)
            }
            return otherAnimatedFields[target.layer]?.first { $0.target == target }
        }
        return constants[target.layer]?.first { $0.target == target }
    }
}
