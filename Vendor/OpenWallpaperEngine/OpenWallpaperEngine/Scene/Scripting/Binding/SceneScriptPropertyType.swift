import Foundation

/// The type a bound property has for WE's value converter (scenescript64.dll `0x181620e10`, a
/// switch over the property's type; plan §1.9 P3). It decides what `init`/`update` receive and
/// which returns are applied. From the converter's cases:
///
/// - `number`: `IsNumber` (NaN and ±Infinity pass and are written), stored as a float.
/// - `bool`: `IsBoolean` only (`0x180016fe0` tests the oddball kind for true/false): a number or a
///   string returned for a flag leaves it unchanged.
/// - `string`: anything but `null`/`undefined`, through `ToString` (a number becomes its text, an
///   object its `toString()`); a `ToString` that throws leaves the value unchanged.
/// - `vec2`/`vec3`/`vec4`: an object whose `x`, `y` (, `z`, `w`) are all numbers, or a number,
///   broadcast to every component. Nothing else: a string such as `"1 2 3"` is rejected.
/// - `degrees`: a `vec3` the converter multiplies by π/180 (its flag bit 4) before storing; scripts
///   see degrees (`angles`).
///
/// The converter also has an Int32 case (`IsNumber`, then `ToInt32`) and an inert one; which WE
/// properties use them is not known, so every numeric property here is a `number`.
enum SceneScriptPropertyType: String {
    case number, bool, string, vec2, vec3, vec4, degrees

    /// Components of a vector type; 1 for the others.
    var components: Int {
        switch self {
        case .vec2: return 2
        case .vec3, .degrees: return 3
        case .vec4: return 4
        case .number, .bool, .string: return 1
        }
    }

    /// The type of a vector with `count` components, or `number` for one.
    static func vector(_ count: Int) -> SceneScriptPropertyType {
        switch count {
        case 2: return .vec2
        case 3: return .vec3
        case 4: return .vec4
        default: return .number
        }
    }

    /// The type of scene.json field `path` (relative to its object, or `general.<key>`), from the
    /// object model's typed field lists; fields they don't list (shader constants, `brightness`, …)
    /// take the shape of their authored `value`.
    init(fieldPath path: [String], value: SceneJSON?) {
        if let known = Self.known(path) {
            self = known
        } else {
            self = Self.shape(of: value)
        }
    }

    private static func known(_ path: [String]) -> SceneScriptPropertyType? {
        guard let key = path.last else { return nil }
        switch path.first {
        case "general":
            guard path.count == 2 else { return nil }
            return SceneScriptSceneField(rawValue: key).map { Self(objectType: $0.type) }
        case "instanceoverride":
            guard path.count == 2 else { return nil }
            let field = SceneScriptObjectField.allCases.first { $0.group == .instance && $0.scriptName == key }
            return field.map { Self(objectType: $0.type) }
        case "effects":
            return path.count == 3 && key == "visible" ? .bool : nil
        default:
            guard path.count == 1 else { return nil }
            if SceneScriptStringField(rawValue: key) != nil { return .string }
            let field = SceneScriptObjectField.allCases.first { $0.group == .layer && $0.scriptName == key }
            return field.map { Self(objectType: $0.type) }
        }
    }

    private init(objectType: SceneScriptObjectField.ValueType) {
        switch objectType {
        case .number: self = .number
        case .bool: self = .bool
        case .vec2: self = .vec2
        case .vec3: self = .vec3
        case .degrees: self = .degrees
        }
    }

    /// The type an authored value's shape implies: a flag, a number, text of 2–4 numbers (WE's
    /// vector form, `"1 0.5 0"`), or other text.
    static func shape(of value: SceneJSON?) -> SceneScriptPropertyType {
        switch value {
        case .bool?: return .bool
        case .number?: return .number
        case .string(let text)?:
            guard let numbers = SceneScriptSceneValue.numbers(in: text), numbers.count <= 4 else { return .string }
            return vector(numbers.count)
        case .object(let fields)?:
            return shape(of: fields["value"])
        case .array?, .null?, nil:
            return .number
        }
    }
}
