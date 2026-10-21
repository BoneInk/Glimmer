import Foundation

/// A material file's first pass (`passes[0]`), as the editors change it: the shader, its combos,
/// textures by slot and constants, every other key kept as it was. The Model Editor's Advanced
/// Texture Settings, particle materials, an image layer's Lighting & Reflections and its image
/// tools all edit a material through it; each writes the result with its own writer.
public struct MaterialPassDocument: Hashable, Sendable {
    public var root: [String: SceneJSONValue]

    public init(root: [String: SceneJSONValue]) { self.root = root }

    /// Nil when `document` isn't an object.
    public init?(_ document: SceneJSONValue) {
        guard case .object(let root) = document else { return nil }
        self.root = root
    }

    public init?(json data: Data) {
        guard case .object(let root)? = SceneJSONValue(any: try? JSONSerialization.jsonObject(with: data)) else { return nil }
        self.root = root
    }

    /// The first pass; empty when there is none. Setting it makes one when there is none.
    var pass: [String: SceneJSONValue] {
        get {
            if case .array(let passes)? = root["passes"], case .object(let pass)? = passes.first { return pass }
            return [:]
        }
        set {
            var passes: [SceneJSONValue] = []
            if case .array(let existing)? = root["passes"] { passes = existing }
            if passes.isEmpty { passes = [.object(newValue)] } else { passes[0] = .object(newValue) }
            root["passes"] = .array(passes)
        }
    }

    /// Changes the first pass when there is one; a material without one is left as it is.
    mutating func changeExistingPass(_ change: (inout [String: SceneJSONValue]) -> Void) {
        guard case .array(var passes)? = root["passes"], case .object(var pass)? = passes.first else { return }
        change(&pass)
        passes[0] = .object(pass)
        root["passes"] = .array(passes)
    }

    public var shader: String {
        get { pass["shader"]?.stringValue ?? "generic4" }
        set { pass["shader"] = .string(newValue) }
    }

    public func combo(_ name: String, default fallback: Int) -> Int {
        if case .object(let combos)? = pass["combos"], let value = combos[name]?.doubleValue { return Int(value) }
        return fallback
    }

    public mutating func setCombo(_ name: String, _ value: Int?) {
        var combos: [String: SceneJSONValue] = [:]
        if case .object(let existing)? = pass["combos"] { combos = existing }
        combos[name] = value.map { .number(Double($0)) }
        pass["combos"] = combos.isEmpty ? nil : .object(combos)
    }

    public func texture(_ slot: Int) -> String? {
        if case .array(let textures)? = pass["textures"], slot < textures.count { return textures[slot].stringValue }
        return nil
    }

    /// Sets the texture of `slot`; earlier empty slots are `null`, as WE writes them.
    public mutating func setTexture(_ slot: Int, _ path: String?) {
        var textures: [SceneJSONValue] = []
        if case .array(let existing)? = pass["textures"] { textures = existing }
        while textures.count <= slot { textures.append(.null) }
        textures[slot] = path.map { .string($0) } ?? .null
        while let last = textures.last, last == .null { textures.removeLast() }
        pass["textures"] = .array(textures)
    }

    public func constant(_ key: String) -> [Double]? {
        guard case .object(let values)? = pass["constantshadervalues"], let value = values[key] else { return nil }
        let literal = SceneFieldBinding.literal(of: value) ?? value
        if let number = literal.doubleValue, case .number = literal { return [number] }
        let parts = SceneVector.components(literal)
        return parts.isEmpty ? nil : parts
    }

    /// Sets a constant: one number as a number, more as WE's "x y z" text.
    public mutating func setConstant(_ key: String, _ value: [Double]?) {
        var values: [String: SceneJSONValue] = [:]
        if case .object(let existing)? = pass["constantshadervalues"] { values = existing }
        if let value {
            values[key] = value.count == 1 ? .number(value[0]) : .string(value.map { String(format: "%.5f", $0) }.joined(separator: " "))
        } else {
            values[key] = nil
        }
        pass["constantshadervalues"] = values.isEmpty ? nil : .object(values)
    }

    public func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: SceneJSONValue.object(root).any, options: [.prettyPrinted, .sortedKeys])
    }
}

// MARK: Foundation objects

extension MaterialPassDocument {
    /// The first pass of a material read as Foundation objects; nil when `passes` isn't a list
    /// of objects or is empty.
    static func firstPass(of material: [String: Any]) -> [String: Any]? {
        (material["passes"] as? [[String: Any]])?.first
    }

    /// `material` with its first pass changed by `change`; as it is when `passes` isn't a list of
    /// objects or is empty.
    static func changingFirstPass(of material: [String: Any], _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var copy = material
        var passes = copy["passes"] as? [[String: Any]] ?? []
        guard !passes.isEmpty else { return copy }
        change(&passes[0])
        copy["passes"] = passes
        return copy
    }

    /// The key of a scene effect pass's constants: `constantshadervalues`, or the older
    /// `constants` a pass has without it.
    static func constantsKey(of pass: [String: Any]) -> String {
        pass["constantshadervalues"] != nil || pass["constants"] == nil ? "constantshadervalues" : "constants"
    }

    /// A scene effect pass's constants (under `constantsKey(of:)`); nil when they aren't an object.
    static func constants(of pass: [String: Any]) -> [String: Any]? {
        pass[constantsKey(of: pass)] as? [String: Any]
    }
}
