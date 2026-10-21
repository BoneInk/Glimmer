import Foundation

/// WE's conversion of a user property's stored text ("true", "0.5", "1 0 0", a combo's value, a
/// text input's text) into the JSON value a binding site or a script reads. One place, so every
/// binding (`UserPropertyBindingTable`) and every script read (`SceneScriptUserProperties`)
/// converts the same way.
enum UserPropertyValueConversion {
    /// The value a bound site takes: the condition flag for the condition form, else `text` in
    /// the type of the site's authored `value`. A property whose text has no meaning in that type
    /// (a non-numeric combo value bound to a number) leaves the authored value.
    static func siteValue(_ text: String, condition: String?, default authored: SceneJSON?) -> SceneJSON {
        if let condition {
            // The flag, in the authored value's type (an `alpha` of 1 bound this way is 1 or 0).
            let flag = matches(text, condition)
            switch authored {
            case .number?: return .number(flag ? 1 : 0)
            case .string?: return .string(flag ? "1" : "0")
            default: return .bool(flag)
            }
        }
        switch authored {
        case .bool?:
            if let flag = flag(text) { return .bool(flag) }
            return authored ?? .null
        case .number?:
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if let number = Double(trimmed) { return .number(number) }
            if let value = ShaderValue(string: trimmed) { return .number(Double(value.float)) }
            return authored ?? .null
        case .string(let literal)?:
            // A vector or number written as text ("1 0.5 0"): the property's numbers, as text.
            if ShaderValue(string: literal) != nil {
                guard ShaderValue(string: text) != nil else { return .string(literal) }
                return .string(text.trimmingCharacters(in: .whitespaces))
            }
            return .string(text)
        case nil, .null?:
            if let number = Double(text.trimmingCharacters(in: .whitespaces)) { return .number(number) }
            if let flag = flag(text) { return .bool(flag) }
            return .string(text)
        case .array?, .object?:
            return authored ?? .null
        }
    }

    /// The value a script reads (`applyUserProperties`, `engine.userProperties`), in the type
    /// project.json declares the property with (`type`, and its declared `value`).
    static func scriptValue(_ text: String, type: String, declared: SceneJSON) -> SceneJSON {
        switch type {
        case "bool":
            return .bool(flag(text) ?? false)
        case "slider":
            return Double(text).map(SceneJSON.number) ?? declared
        default:
            // Combos keep their options' type; colours and text stay text (WE's
            // `convertUserProperties` turns colours into `Vec3` in the runtime).
            if case .number = declared, let number = Double(text) { return .number(number) }
            if case .bool = declared { return .bool(flag(text) ?? false) }
            return .string(text)
        }
    }

    /// WE condition compare: numeric when both sides are numbers ("1" == "1.0"), else the combo
    /// option's letters and digits, ignoring case ("Two" == "two").
    static func matches(_ property: String, _ condition: String) -> Bool {
        let lhs = property.trimmingCharacters(in: .whitespaces)
        let rhs = condition.trimmingCharacters(in: .whitespaces)
        if let a = ShaderValue(string: lhs), let b = ShaderValue(string: rhs) { return a == b }
        return SceneUserVisibility.normalizeVariant(lhs) == SceneUserVisibility.normalizeVariant(rhs)
    }

    /// "true"/"false" (any case) and numbers (non-zero is true); nil for anything else.
    static func flag(_ text: String) -> Bool? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.caseInsensitiveCompare("true") == .orderedSame { return true }
        if trimmed.caseInsensitiveCompare("false") == .orderedSame { return false }
        if let number = Double(trimmed) { return number != 0 }
        return nil
    }
}
