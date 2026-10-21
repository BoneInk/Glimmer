import Foundation
import OWEControlProtocol
import OWESceneEditing

/// The control channel's JSON and the editor's scene values (`SceneJSONValue`), both ways, and
/// a value a client sends as text read the way scene.json writes it.
enum SceneControlValues {
    static func json(_ value: SceneJSONValue) -> JSONValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(json))
        case .object(let object): return .object(object.mapValues(json))
        }
    }

    static func json(_ value: SceneJSONValue?) -> JSONValue {
        value.map(json) ?? .null
    }

    static func scene(_ value: JSONValue) -> SceneJSONValue {
        switch value {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .number(let number): return .number(number)
        case .string(let text): return .string(text)
        case .array(let items): return .array(items.map(scene))
        case .object(let object): return .object(object.mapValues(scene))
        }
    }

    /// A value given as text, as the scene writes it: `true`/`false`, a number, a JSON array or
    /// object, or else the text itself (a vector such as `"1 0.5 0"` stays text, as WE writes
    /// vectors). `like` is the value it replaces: text stays text when that is text (a name, a
    /// font, a vector), a number becomes a number.
    static func parse(_ text: String, like current: SceneJSONValue? = nil) -> SceneJSONValue {
        if case .string? = current { return .string(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default: break
        }
        if let number = Double(trimmed), number.isFinite, trimmed.rangeOfCharacter(from: .whitespaces) == nil { return .number(number) }
        if let first = trimmed.first, first == "[" || first == "{",
           let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data), // Not JSON: it is text.
           let value = SceneJSONValue(any: object) {
            return value
        }
        return .string(text)
    }

    /// A vector of `count` numbers given as `"x y z"` (or fewer: the rest from `fallback`).
    static func vector(_ text: String, count: Int, fallback: [Double], name: String) throws -> [Double] {
        let parts = SceneVector.tokens(text).map(String.init)
        let numbers = parts.compactMap(Double.init)
        guard !parts.isEmpty, numbers.count == parts.count, numbers.count <= count else {
            throw ControlError(.invalidParams, "\(name) must be up to \(count) numbers separated by spaces, such as \"\(Array(repeating: "0", count: count).joined(separator: " "))\".")
        }
        var result = fallback
        while result.count < count { result.append(0) }
        for (index, number) in numbers.enumerated() { result[index] = number }
        return Array(result.prefix(count))
    }
}
