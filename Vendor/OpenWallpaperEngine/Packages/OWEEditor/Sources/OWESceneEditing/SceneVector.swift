import Foundation

/// scene.json's vectors: `"x y z"` strings (WE's own form), plus the arrays, `{x,y,z}` objects
/// and single numbers some files use.
public enum SceneVector {
    /// The components of `value`; empty when it isn't a vector.
    public static func components(_ value: SceneJSONValue?) -> [Double] {
        guard let value else { return [] }
        switch value {
        case .string(let text):
            return numbers(text)
        case .number(let number):
            return [number]
        case .array(let values):
            return values.compactMap(\.doubleValue)
        case .object(let values):
            return ["x", "y", "z", "w"].compactMap { values[$0]?.doubleValue }
        default:
            return []
        }
    }

    /// Where WE's vector text splits: spaces and commas, or also tabs and newlines.
    public enum Separators: Sendable {
        case spacesAndCommas
        case whitespaceAndCommas
    }

    /// The tokens of WE's `"x y z"` text, the empty ones between separators dropped.
    public static func tokens(_ text: String, separatedBy separators: Separators = .spacesAndCommas) -> [Substring] {
        switch separators {
        case .spacesAndCommas:
            return text.split(whereSeparator: { $0 == " " || $0 == "," })
        case .whitespaceAndCommas:
            return text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "," })
        }
    }

    /// The numbers of WE's `"x y z"` text; a token that isn't a number is skipped.
    public static func numbers(_ text: String) -> [Double] {
        tokens(text).compactMap { Double($0) }
    }

    /// `numbers` read as `Float`s (each token parsed as a Float, not rounded from a Double).
    public static func floats(_ text: String) -> [Float] {
        tokens(text).compactMap { Float($0) }
    }

    /// `components` padded with `fallback`'s to its length.
    public static func components(_ value: SceneJSONValue?, fallback: [Double]) -> [Double] {
        let parsed = components(value)
        return fallback.indices.map { parsed.indices.contains($0) ? parsed[$0] : fallback[$0] }
    }

    /// WE's string form: whole numbers without a fraction, others with up to six digits.
    public static func string(_ components: [Double]) -> String {
        components.map(format).joined(separator: " ")
    }

    public static func value(_ components: [Double]) -> SceneJSONValue {
        .string(string(components))
    }

    static func format(_ number: Double) -> String {
        guard number.isFinite else { return "0" }
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        var text = String(format: "%.6f", number)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
