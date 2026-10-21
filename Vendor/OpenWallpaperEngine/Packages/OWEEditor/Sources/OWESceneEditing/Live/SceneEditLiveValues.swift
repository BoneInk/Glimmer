import Foundation

/// What a running wallpaper draws differently from the scene it built, when the overlay changed
/// only in values the renderer can take per frame: a layer's transform, opacity and colour, and an
/// effect's visibility and constants. Anything else (a layer or effect added, a combo, a texture,
/// a binding, a field a script drives) needs the scene read again, and `make` returns nil.
///
/// The running wallpaper built its content with `built`; the editor now has `current`. Both are
/// read over `base`, the scene with the structural edits (which must match for live values).
public struct SceneEditLiveValues: Hashable, Sendable {
    /// One layer's change: each field's value as built and as it is now.
    public struct Layer: Hashable, Sendable {
        public var origin: (built: SIMD3<Double>, now: SIMD3<Double>)?
        public var scale: (built: SIMD3<Double>, now: SIMD3<Double>)?
        public var angles: (built: SIMD3<Double>, now: SIMD3<Double>)?
        public var alpha: (built: Double, now: Double)?
        public var color: (built: SIMD3<Double>, now: SIMD3<Double>)?

        public init() {}

        public var isEmpty: Bool { origin == nil && scale == nil && angles == nil && alpha == nil && color == nil }

        public static func == (lhs: Layer, rhs: Layer) -> Bool {
            func same<T: Equatable>(_ a: (built: T, now: T)?, _ b: (built: T, now: T)?) -> Bool {
                a?.built == b?.built && a?.now == b?.now
            }
            return same(lhs.origin, rhs.origin) && same(lhs.scale, rhs.scale) && same(lhs.angles, rhs.angles)
                && same(lhs.alpha, rhs.alpha) && same(lhs.color, rhs.color)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(origin?.now.x)
            hasher.combine(scale?.now.x)
            hasher.combine(angles?.now.z)
            hasher.combine(alpha?.now)
            hasher.combine(color?.now.x)
        }
    }

    /// One effect's change, by its index in the layer's `effects` (the renderer's `effectIndex`).
    public struct Effect: Hashable, Sendable {
        public var visible: Bool?
        /// Constants to write over the built ones, by key: their components now.
        public var constants: [String: [Double]] = [:]

        public init(visible: Bool? = nil, constants: [String: [Double]] = [:]) {
            self.visible = visible
            self.constants = constants
        }
    }

    public var layers: [Int: Layer] = [:]
    /// By layer id, then effect index.
    public var effects: [Int: [Int: Effect]] = [:]

    public init() {}

    public var isEmpty: Bool { layers.isEmpty && effects.isEmpty }

    /// Fields a layer can change live.
    static let liveFields: Set<String> = ["origin", "scale", "angles", "alpha", "color"]

    /// The live values that take a wallpaper built with `built` to `current`; nil when the
    /// difference needs the scene read again. `base` is `SceneEditSession.baseOutline`.
    public static func make(built: SceneEditOverlay, current: SceneEditOverlay, base: SceneOutline) -> SceneEditLiveValues? {
        // The scene's settings are read when the scene is.
        // So are the documents its layers read (an edited material).
        guard built.structureOnly == current.structureOnly, built.general == current.general,
              built.documents == current.documents else { return nil }
        var result = SceneEditLiveValues()
        let keys = Set(built.objects.keys).union(current.objects.keys)
        for key in keys {
            guard let id = Int(key) else { continue }
            let was = built.objects[key] ?? SceneEditOverlay.ObjectEdit()
            let now = current.objects[key] ?? SceneEditOverlay.ObjectEdit()
            let layer = base.layer(id)
            // Fields: the live ones only, and only where the scene doesn't drive or bind them.
            var live = Layer()
            for field in Set(was.fields.keys).union(now.fields.keys) where was.fields[field] != now.fields[field] {
                guard liveFields.contains(field), let layer, SceneFieldBinding(layer.fields[field]) != .driven else { return nil }
                if case .userProperty = SceneFieldBinding(layer.fields[field]) { return nil }
                let authored = SceneFieldBinding.literal(of: layer.fields[field])
                let before = was.fields[field] ?? authored, after = now.fields[field] ?? authored
                switch field {
                case "alpha":
                    live.alpha = (before?.doubleValue ?? 1, after?.doubleValue ?? 1)
                case "origin":
                    live.origin = (vector(before, .zero), vector(after, .zero))
                case "scale":
                    live.scale = (vector(before, .one), vector(after, .one))
                case "angles":
                    live.angles = (vector(before, .zero), vector(after, .zero))
                default:
                    live.color = (vector(before, .one), vector(after, .one))
                }
            }
            if !live.isEmpty { result.layers[id] = live }
            // Effects: visibility and constant values.
            var effects: [Int: Effect] = [:]
            for effectKey in Set(was.effects.keys).union(now.effects.keys) {
                let before = was.effects[effectKey] ?? SceneEditOverlay.EffectEdit()
                let after = now.effects[effectKey] ?? SceneEditOverlay.EffectEdit()
                guard before != after else { continue }
                guard before.combos == after.combos, before.textures == after.textures, before.bindings == after.bindings,
                      let layer, let index = layer.effects.firstIndex(where: { $0.key == effectKey }) else { return nil }
                let effect = layer.effects[index]
                var change = Effect()
                if before.visible != after.visible {
                    if case .userProperty = SceneFieldBinding(effect.visible) { return nil }
                    change.visible = after.visible ?? SceneFieldBinding.literal(of: effect.visible)?.boolValue ?? true
                }
                for constant in Set(before.constants.keys).union(after.constants.keys)
                where before.constants[constant] != after.constants[constant] {
                    let authored = effect.constants.first { $0.key.caseInsensitiveCompare(constant) == .orderedSame }?.value
                    // A bound or driven constant isn't a plain value to write over.
                    guard SceneFieldBinding(authored) == .literal || authored == nil else { return nil }
                    // An edit dropped falls back to the scene's value, or, where the scene has
                    // none, to the shader's default, which only a fresh read knows.
                    guard let value = after.constants[constant] ?? authored else { return nil }
                    let components = SceneVector.components(value)
                    guard !components.isEmpty else { return nil }
                    change.constants[constant] = components
                }
                effects[index] = change
            }
            if !effects.isEmpty { result.effects[id] = effects }
        }
        return result
    }

    static func vector(_ value: SceneJSONValue?, _ fallback: SIMD3<Double>) -> SIMD3<Double> {
        let components = SceneVector.components(value, fallback: [fallback.x, fallback.y, fallback.z])
        return SIMD3(components[0], components[1], components[2])
    }
}
