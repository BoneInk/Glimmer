import Foundation
import OWESceneEditing

/// A resolved shader constant: one to four (or more, for arrays) float components.
///
/// WE stores vectors as space-separated strings ("1 0.5 0.25"), scalars as numbers, and
/// toggles as booleans; all of them end up here.
struct ShaderValue: Equatable {
    var components: [Float]

    init(components: [Float]) { self.components = components }
    init(_ value: Float) { components = [value] }
    init(_ value: Bool) { components = [value ? 1 : 0] }

    /// Parses a WE value string. Accepts "1", "1 0.5 0.25", extra/leading/trailing whitespace,
    /// and "true"/"false". Returns nil if any token is not a number.
    init?(string: String) {
        let tokens = SceneVector.tokens(string, separatedBy: .whitespaceAndCommas)
        guard !tokens.isEmpty else { return nil }
        if tokens.count == 1 {
            switch tokens[0].lowercased() {
            case "true": self.init(true); return
            case "false": self.init(false); return
            default: break
            }
        }
        var parsed: [Float] = []
        parsed.reserveCapacity(tokens.count)
        for token in tokens {
            guard let value = Float(token) else { return nil }
            parsed.append(value)
        }
        self.init(components: parsed)
    }

    /// Parses JSONSerialization output: NSNumber (number or bool) or String.
    init?(json: Any) {
        if let number = json as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self.init(number.boolValue)
            } else {
                self.init(number.floatValue)
            }
        } else if let string = json as? String {
            self.init(string: string)
        } else {
            return nil
        }
    }

    static let zero = ShaderValue(0)

    /// Components resized to `count`: extra components are dropped, missing ones are 0.
    func padded(to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        if components.count >= count { return Array(components.prefix(count)) }
        return components + Array(repeating: 0, count: count - components.count)
    }

    /// Same value resized to `count` components.
    func resized(to count: Int) -> ShaderValue { ShaderValue(components: padded(to: count)) }

    /// Components rounded to the nearest integer, for uniforms annotated `"int": true`.
    func roundedToIntegers() -> ShaderValue {
        ShaderValue(components: components.map { $0.rounded() })
    }

    var float: Float { components.first ?? 0 }
    var vec2: SIMD2<Float> { let c = padded(to: 2); return SIMD2(c[0], c[1]) }
    var vec3: SIMD3<Float> { let c = padded(to: 3); return SIMD3(c[0], c[1], c[2]) }
    var vec4: SIMD4<Float> { let c = padded(to: 4); return SIMD4(c[0], c[1], c[2], c[3]) }
}
