import Foundation
import WEFormat

/// One of an effect's canvas gizmos, as its `effect.json` lists them under `gizmos`: a type, the
/// constants (`constantshadervalues` keys) each of its handles sets (`vars`), and the combo values
/// it shows for (`condition`). Wallpaper Engine's built-in effects use five types.
public struct EffectGizmo: Hashable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Four corners `p0`…`p3` of a quad in the layer's UV (Perspective, Clouds, Light Shafts…).
        case perspectiveUV = "EffectPerspectiveUV"
        /// A `center`, a `size` (radius), an ellipse's `ratio` and `angle` (Spin, Twirl).
        case spinUV = "EffectSpinUV"
        /// A hinge `p0`–`p1`, the page's `size` and the swing's `center` along it (Swing).
        case swingUV = "EffectSwingUV"
        /// A point emitter's `center`, `size`, `angle` and `speed` (Advanced Fluid Simulation).
        case pointEmitter = "EffectPointEmitter"
        /// A line emitter from `p0` to `p1` with `size`, `angle` and `speed`.
        case lineEmitter = "EffectLineEmitter"
    }

    /// A combo's value the gizmo needs: `{"PERSPECTIVE": 1}` or `{"POINTEMITTER": {"op": "ge", "value": 2}}`.
    public struct Condition: Hashable, Sendable {
        public var combo: String
        /// `eq`, `ne`, `ge`, `gt`, `le` or `lt`.
        public var op: String
        public var value: Int

        public init(combo: String, op: String = "eq", value: Int) {
            self.combo = combo
            self.op = op
            self.value = value
        }

        public func holds(_ current: Int) -> Bool {
            switch op.lowercased() {
            case "ne": return current != value
            case "ge", "gte": return current >= value
            case "gt": return current > value
            case "le", "lte": return current <= value
            case "lt": return current < value
            default: return current == value
            }
        }
    }

    public var kind: Kind
    /// The gizmo's role (`center`, `p0`…) to the effect's constant it sets.
    public var vars: [String: String]
    public var conditions: [Condition]

    public init(kind: Kind, vars: [String: String], conditions: [Condition] = []) {
        self.kind = kind
        self.vars = vars
        self.conditions = conditions
    }

    /// The constant behind `role`, if the gizmo names one.
    public func key(_ role: String) -> String? { vars[role] }

    /// Whether the gizmo shows with the effect's combos as `combo` reads them.
    public func shows(combo: (String) -> Int) -> Bool {
        conditions.allSatisfy { $0.holds(combo($0.combo)) }
    }

    /// The gizmos of an `effect.json` (WE's tolerant JSON: comments, trailing commas). An entry of
    /// an unknown type is left out, so one the editor can't draw doesn't drop its siblings.
    public static func gizmos(effectJSON data: Data) throws -> [EffectGizmo] {
        guard let root = try TolerantJSON.object(from: data) as? [String: Any] else { return [] }
        return gizmos(root["gizmos"])
    }

    static func gizmos(_ value: Any?) -> [EffectGizmo] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item -> EffectGizmo? in
            guard let entry = item as? [String: Any], let type = entry["type"] as? String,
                  let kind = Kind(rawValue: type) else { return nil }
            var vars: [String: String] = [:]
            for (role, key) in entry["vars"] as? [String: Any] ?? [:] {
                if let key = key as? String { vars[role] = key }
            }
            var conditions: [Condition] = []
            for (combo, rule) in entry["condition"] as? [String: Any] ?? [:] {
                if let number = rule as? NSNumber {
                    conditions.append(Condition(combo: combo, value: number.intValue))
                } else if let rule = rule as? [String: Any], let value = rule["value"] as? NSNumber {
                    conditions.append(Condition(combo: combo, op: rule["op"] as? String ?? "eq", value: value.intValue))
                }
            }
            return EffectGizmo(kind: kind, vars: vars, conditions: conditions.sorted { $0.combo < $1.combo })
        }
    }
}
