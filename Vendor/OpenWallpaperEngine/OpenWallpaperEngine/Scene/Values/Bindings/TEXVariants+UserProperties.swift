import Foundation

extension TEXVariants.Condition {
    /// Whether the condition holds with `properties`, as WE's loader asks its user properties:
    /// a bool property's value, or whether a combo property has the condition's value. A property
    /// with no value doesn't hold.
    func isMet(_ properties: (String) -> String?) -> Bool {
        guard let text = properties(property) else { return false }
        switch self {
        case .flag: return UserPropertyValueConversion.flag(text) ?? false
        case .equals(_, let value): return UserPropertyValueConversion.matches(text, value)
        }
    }

    /// The condition as a `{"user": …}` binding, which `UserPropertyBindingTable` records so a
    /// change of the property rebuilds what reads the texture.
    var binding: SceneJSON {
        switch self {
        case .flag(let property):
            return .object(["user": .string(property), "value": .bool(false)])
        case .equals(let property, let value):
            return .object(["user": .object(["name": .string(property), "condition": .string(value)]), "value": .bool(false)])
        }
    }
}

extension TEXVariants {
    /// The options' conditions as a document of bindings, recorded under the texture's path.
    var bindingDocument: SceneJSON {
        .object(["variants": .array(options.compactMap { $0.condition?.binding })])
    }
}
