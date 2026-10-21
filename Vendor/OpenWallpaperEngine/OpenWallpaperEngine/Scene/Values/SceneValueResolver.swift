import Foundation

/// Resolves a `SceneValueSource` to its current value with WE's binding semantics.
enum SceneValueResolver {
    static func resolve(_ source: SceneValueSource, in context: SceneValueContext) -> ShaderValue {
        switch source {
        case .literal(let value):
            return value

        case let .user(name, condition, fallback):
            guard let property = context.userProperty(name) else {
                return resolve(fallback, in: context)
            }
            if let condition {
                return ShaderValue(matches(property, condition))
            }
            if let value = ShaderValue(string: property) {
                return value
            }
            // A combo whose value is a non-numeric string has no shader meaning of its own.
            OWELog.debug(.scene, "SceneValueResolver: user property '\(name)' = '\(property)' is not numeric; using fallback")
            return resolve(fallback, in: context)

        case let .script(_, _, fallback):
            // The script runs in the wallpaper's SceneScript runtime, which owns the value from its
            // first write (the renderer reads it from the object table); this is the value it starts from.
            return resolve(fallback, in: context)

        case let .animation(site, fallback):
            // One component per channel (`c0`…); the uniform's type shapes it (`ShaderConstantResolver.shape`).
            guard let site, let value = context.animationValue(site) else { return resolve(fallback, in: context) }
            return ShaderValue(components: value)
        }
    }

    /// WE condition compare (`UserPropertyValueConversion.matches`).
    static func matches(_ property: String, _ condition: String) -> Bool {
        UserPropertyValueConversion.matches(property, condition)
    }
}

