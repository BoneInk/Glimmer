import Foundation

/// A field of one scene object as scene.json nests it: `alpha`, `origin`, `text`, or an effect's
/// `effects.1.visible`. Scripts and user-property bindings attach to a field (docs/scenescript-plan.md
/// §1.2: "a script is bound to one property"); the runtime names a script by the same path.
public struct SceneFieldPath: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ path: String) {
        components = path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    public init(components: [String]) {
        self.components = components
    }

    /// `effects.<index>.<field>`.
    public static func effect(_ index: Int, _ field: String = "visible") -> SceneFieldPath {
        SceneFieldPath(components: ["effects", String(index), field])
    }

    /// The field WE's editor gives a script that isn't about one value (the d.ts: "the Visibility
    /// property is typically used" for general-purpose scripts).
    public static let objectScript = SceneFieldPath("visible")

    public var description: String { components.joined(separator: ".") }

    /// The object field (`alpha`), or nil for a nested one.
    public var objectField: String? { components.count == 1 ? components[0] : nil }

    /// The effect index of an effect's field.
    public var effectIndex: Int? {
        guard components.count >= 3, components[0] == "effects" else { return nil }
        return Int(components[1])
    }

    /// The last component: the field's own name (`visible` of `effects.0.visible`).
    public var name: String { components.last ?? "" }

    public static func < (lhs: SceneFieldPath, rhs: SceneFieldPath) -> Bool {
        lhs.description < rhs.description
    }

    // MARK: Reading and writing a decoded object

    /// The value at the path inside `object`; nil when a step is missing.
    public func value(in object: [String: Any]) -> Any? {
        var current: Any? = object
        for component in components {
            if let index = Int(component), let array = current as? [Any] {
                guard array.indices.contains(index) else { return nil }
                current = array[index]
            } else if let dictionary = current as? [String: Any] {
                current = dictionary[component]
            } else {
                return nil
            }
        }
        return current
    }

    /// Sets the value at the path (nil removes it). Missing objects on the way are created; a
    /// missing array element (an effect the scene no longer has) leaves `object` as it was.
    public func set(_ value: Any?, in object: inout [String: Any]) {
        guard let first = components.first else { return }
        let rest = components.dropFirst()
        if rest.isEmpty {
            object[first] = value
        } else if let updated = Self.set(value, at: rest, in: object[first]) {
            object[first] = updated
        }
    }

    /// The container with the value set; nil when the path can't be followed (leave it as it was).
    private static func set(_ value: Any?, at path: ArraySlice<String>, in container: Any?) -> Any? {
        guard let key = path.first else { return value }
        let rest = path.dropFirst()
        if let index = Int(key), var array = container as? [Any] {
            guard array.indices.contains(index) else { return nil }
            if rest.isEmpty {
                guard let value else { return nil } // An array element isn't removed by a field edit.
                array[index] = value
            } else {
                guard let updated = set(value, at: rest, in: array[index]) else { return nil }
                array[index] = updated
            }
            return array
        }
        if container != nil, !(container is [String: Any]) { return nil }
        var dictionary = container as? [String: Any] ?? [:]
        if rest.isEmpty {
            dictionary[key] = value
        } else {
            guard let updated = set(value, at: rest, in: dictionary[key]) else { return nil }
            dictionary[key] = updated
        }
        return dictionary
    }
}

extension SceneFieldPath: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension SceneFieldPath: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}
