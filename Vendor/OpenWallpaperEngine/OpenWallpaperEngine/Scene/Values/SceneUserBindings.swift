import Foundation

extension SceneRawValue {
    /// The value's user binding over its literal, without any script or animation (those run in
    /// their own per-frame paths). Nil when the value isn't user-bound.
    var userBindingSource: SceneValueSource? {
        guard case .object(let object) = self, let name = object.userName else { return nil }
        let literal = object.value?.literalString.flatMap(ShaderValue.init(string:)) ?? .zero
        return .user(name: name, condition: object.userCondition, fallback: .literal(literal))
    }
}

extension SceneObjectValueField {
    /// Resolves a binding of this field. A scalar property bound to `scale` or `color` (a slider)
    /// applies to every axis/channel.
    func resolve(_ source: SceneValueSource, in context: SceneValueContext) -> ShaderValue {
        let value = SceneValueResolver.resolve(source, in: context)
        guard value.components.count == 1, self == .scale || self == .color else { return value }
        return ShaderValue(components: Array(repeating: value.float, count: 3))
    }
}
