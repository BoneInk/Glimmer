import Foundation
import OWESceneEditing

/// Authored scene.json values in WE's forms (a number, a flag, `"1 0.5 0"` for vectors and
/// colours, text) as the values a bound property holds for scripts. `sceneScriptBinding.js` reads
/// user property values the same way when they change.
enum SceneScriptSceneValue {
    /// The numbers of WE's vector text, or nil when a part is not a number (or there is none).
    static func numbers(in text: String) -> [Double]? {
        let parts = SceneVector.tokens(text, separatedBy: .whitespaceAndCommas)
        guard !parts.isEmpty else { return nil }
        var numbers: [Double] = []
        numbers.reserveCapacity(parts.count)
        for part in parts {
            guard let number = Double(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// `value` as a property of `type` holds it for JavaScript: a number, a flag, a string, or
    /// `{x, y[, z[, w]]}` for vectors (one number fills every component, missing ones are 0). With
    /// `condition` (a `{"user": {"name", "condition"}}` binding) a flag is whether the value's text
    /// equals it. Nil when the value can't be one of `type`.
    static func javaScriptValue(_ value: SceneJSON, as type: SceneScriptPropertyType,
                                condition: String? = nil) -> Any? {
        if let condition, type == .bool {
            guard let text = value.scalarString else { return nil }
            return text == condition
        }
        switch type {
        case .bool: return flag(value)
        case .number: return components(value, count: 1)?.first
        case .string:
            if case .string(let text) = value { return text }
            return value.scalarString
        case .vec2, .vec3, .vec4, .degrees:
            guard let numbers = components(value, count: type.components) else { return nil }
            let keys = ["x", "y", "z", "w"]
            var object: [String: Double] = [:]
            for (index, number) in numbers.enumerated() { object[keys[index]] = number }
            return object
        }
    }

    private static func flag(_ value: SceneJSON) -> Bool? {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    /// `count` numbers from a number, a flag or vector text: one number is broadcast, missing
    /// components are 0 and extra ones are dropped.
    private static func components(_ value: SceneJSON, count: Int) -> [Double]? {
        let numbers: [Double]
        switch value {
        case .number(let number): numbers = [number]
        case .bool(let flag): numbers = [flag ? 1 : 0]
        case .string(let text):
            guard let parsed = Self.numbers(in: text) else { return nil }
            numbers = parsed
        default: return nil
        }
        if numbers.count == 1 { return Array(repeating: numbers[0], count: count) }
        return (0..<count).map { $0 < numbers.count ? numbers[$0] : 0 }
    }
}
