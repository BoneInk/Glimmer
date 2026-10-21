import Foundation

/// A particle system's JSON (`particles/….json`) as the particle editor changes it: the root's
/// fields, and the lists of emitters, initializers, operators, renderers, children and control
/// points, each item a component of `ParticleEditorSchema`. Written back the way WE writes it.
public struct ParticleDefinition: Hashable, Sendable {
    public typealias Section = ParticleEditorSchema.Section
    public typealias Item = [String: SceneJSONValue]

    public private(set) var root: Item

    public init(root: Item) {
        self.root = root
    }

    /// Nil when `json` isn't an object.
    public init?(json: SceneJSONValue) {
        guard case .object(let root) = json else { return nil }
        self.root = root
    }

    public init(data: Data) throws {
        guard let value = SceneJSONValue(any: try JSONSerialization.jsonObject(with: data)),
              let definition = ParticleDefinition(json: value) else { throw ParticleDefinitionError.notAnObject }
        self = definition
    }

    public var json: SceneJSONValue { .object(root) }

    /// The JSON as WE's editor writes a particle file: indented, its keys sorted.
    public func encoded() throws -> Data {
        try Self.encode(json)
    }

    /// A JSON document as the editor writes WE's files: indented, keys sorted, whole numbers
    /// without a fraction.
    public static func encode(_ value: SceneJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    // MARK: Root

    public subscript(key: String) -> SceneJSONValue? {
        get { root[key] }
        set { root[key] = newValue }
    }

    /// `material`: the material file the system draws with.
    public var materialPath: String? {
        get { root["material"]?.stringValue }
        set { root["material"] = newValue.map(SceneJSONValue.string) }
    }

    /// The particle files of `children`, in order.
    public var childPaths: [String] {
        items(.children).compactMap { $0["name"]?.stringValue }
    }

    // MARK: Lists

    /// The items of a list; an authored `null` (WE writes `"children": null`) is an empty list.
    public func items(_ section: Section) -> [Item] {
        guard let key = section.listKey, case .array(let values)? = root[key] else { return [] }
        return values.map { value in
            if case .object(let item) = value { return item }
            return [:]
        }
    }

    public func item(_ section: Section, at index: Int) -> Item? {
        let items = items(section)
        return items.indices.contains(index) ? items[index] : nil
    }

    private mutating func setItems(_ items: [Item], _ section: Section) {
        guard let key = section.listKey else { return }
        root[key] = .array(items.map(SceneJSONValue.object))
    }

    public mutating func updateItem(_ section: Section, at index: Int, _ change: (inout Item) -> Void) {
        var items = items(section)
        guard items.indices.contains(index) else { return }
        change(&items[index])
        setItems(items, section)
    }

    /// The most items WE reads of a list: eight control points (`ParticleControlPoint.count`).
    public static func capacity(of section: Section) -> Int {
        section == .controlpoint ? 8 : .max
    }

    /// Adds `component` at the end of its list with the values WE's editor writes when it adds
    /// one (`add_default`, the 3D value in a perspective scene), its `name`, and an `id` no other
    /// component of the system has. Returns its index; nil when the list is full.
    @discardableResult
    public mutating func add(_ component: ParticleEditorSchema.Component, pixelUnits: Bool) -> Int? {
        guard component.section.listKey != nil else { return nil }
        var items = items(component.section)
        guard items.count < Self.capacity(of: component.section) else { return nil }
        var item = Self.defaults(of: component, pixelUnits: pixelUnits)
        if let name = component.name { item["name"] = .string(name) }
        // A control point's id is its slot; every other component gets the next free id.
        item["id"] = .number(Double(component.section == .controlpoint ? items.count : nextComponentID))
        items.append(item)
        setItems(items, component.section)
        return items.count - 1
    }

    /// An item with the values the editor writes for `component`: each field's default, its
    /// flags' defaults combined into `flags`.
    public static func defaults(of component: ParticleEditorSchema.Component, pixelUnits: Bool) -> Item {
        var item: Item = [:]
        var flags = 0
        var hasFlags = false
        for field in component.fields {
            guard let value = field.defaultValue(pixelUnits: pixelUnits) else { continue }
            if let bit = field.bit {
                hasFlags = true
                if value.boolValue == true { flags |= bit }
            } else if item[field.key] == nil {
                item[field.key] = value
            }
        }
        if hasFlags { item["flags"] = .number(Double(flags)) }
        return item
    }

    public mutating func remove(_ section: Section, at index: Int) {
        var items = items(section)
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        if section == .controlpoint {
            // A control point's place is its id.
            for position in items.indices { items[position]["id"] = .number(Double(position)) }
        }
        setItems(items, section)
    }

    /// Moves the item at `source` to `destination` (its index afterwards). WE runs initializers
    /// and operators in list order, so the order is part of the system.
    public mutating func move(_ section: Section, from source: Int, to destination: Int) {
        var items = items(section)
        guard items.indices.contains(source), items.indices.contains(destination), source != destination else { return }
        let item = items.remove(at: source)
        items.insert(item, at: destination)
        if section == .controlpoint {
            for position in items.indices { items[position]["id"] = .number(Double(position)) }
        }
        setItems(items, section)
    }

    /// One more than the largest `id` among the system's components.
    public var nextComponentID: Int {
        var largest = 0
        for section in Section.lists where section != .controlpoint {
            for item in items(section) {
                if let id = item["id"]?.doubleValue { largest = max(largest, Int(id)) }
            }
        }
        return largest + 1
    }

    // MARK: Fields

    /// The field's authored value in `item` (a flag: whether its bit is set); nil when absent.
    public static func value(of field: ParticleEditorSchema.Field, in item: Item) -> SceneJSONValue? {
        if let bit = field.bit {
            guard let flags = item[field.key]?.doubleValue else { return nil }
            return .bool(Int(flags) & bit != 0)
        }
        return item[field.key]
    }

    /// The value the panel shows: the authored one, else the one the editor writes.
    public static func shownValue(of field: ParticleEditorSchema.Field, in item: Item, pixelUnits: Bool) -> SceneJSONValue? {
        value(of: field, in: item) ?? field.defaultValue(pixelUnits: pixelUnits)
    }

    /// Sets the field in `item`; nil removes the key (a flag: clears its bit).
    public static func set(_ value: SceneJSONValue?, for field: ParticleEditorSchema.Field, in item: inout Item) {
        if let bit = field.bit {
            var flags = Int(item[field.key]?.doubleValue ?? 0)
            if value?.boolValue == true { flags |= bit } else { flags &= ~bit }
            item[field.key] = .number(Double(flags))
            return
        }
        item[field.key] = value
    }

    /// The values `component`'s conditions read in `item`: authored, else the editor's default.
    public static func conditionValues(_ item: Item, component: ParticleEditorSchema.Component,
                                       pixelUnits: Bool) -> ParticleFieldCondition.Values {
        ParticleFieldCondition.Values { key in
            if let value = item[key] { return value }
            if key == "flags" {
                return .number(Double(defaults(of: component, pixelUnits: pixelUnits)["flags"]?.doubleValue ?? 0))
            }
            return component.fields.first { $0.key == key && $0.bit == nil }?.defaultValue(pixelUnits: pixelUnits)
        }
    }

    // MARK: Template

    /// A new system as WE's editor starts one when it has no template file: WE's
    /// `particles/example.json` (`ParticleEditorTemplateTests`).
    public static let template = ParticleDefinition(root: [
        "material": .string("materials/particle/halo.json"),
        "maxcount": .number(500),
        "starttime": .number(0),
        "emitter": .array([.object([
            "name": .string("sphererandom"), "rate": .number(20), "origin": .string("0 0 0"),
            "directions": .string("1 1 0"), "distancemin": .number(32), "distancemax": .number(512),
        ])]),
        "initializer": .array([
            .object(["name": .string("lifetimerandom"), "min": .number(3), "max": .number(5)]),
            .object(["name": .string("sizerandom"), "min": .number(50), "max": .number(200)]),
            .object(["name": .string("velocityrandom"), "min": .string("-50 -50 0"), "max": .string("50 50 0")]),
            .object(["name": .string("colorrandom"), "min": .string("255 255 255"), "max": .string("255 255 255")]),
        ]),
        "operator": .array([
            .object(["name": .string("movement"), "gravity": .string("0 0 0")]),
            .object(["name": .string("alphafade"), "fadeintime": .number(0.5)]),
        ]),
    ])
}

public enum ParticleDefinitionError: Error, Equatable {
    case notAnObject
}

/// A particle material (`materials/….json`) as the system panel edits it: its first pass's
/// texture, blending, depth and culling, and its constants (`ui_editor_properties_overbright`).
public struct ParticleMaterial: Hashable, Sendable {
    public private(set) var root: [String: SceneJSONValue]

    public init(root: [String: SceneJSONValue]) {
        self.root = root
    }

    public init?(json: SceneJSONValue) {
        guard case .object(let root) = json else { return nil }
        self.root = root
    }

    public var json: SceneJSONValue { .object(root) }

    /// The blendings a particle material draws with (`WEMaterialBlending.particleSystem`).
    public static let blendings = ["normal", "translucent", "additive"]
    public static let overbrightKey = "ui_editor_properties_overbright"

    private var pass: [String: SceneJSONValue] {
        get { MaterialPassDocument(root: root).pass }
        set {
            var material = MaterialPassDocument(root: root)
            material.pass = newValue
            root = material.root
        }
    }

    /// The first texture: the particle's sprite (sheet).
    public var texture: String? {
        get {
            if case .array(let textures)? = pass["textures"] { return textures.first?.stringValue }
            return nil
        }
        set {
            var textures: [SceneJSONValue] = []
            if case .array(let authored)? = pass["textures"] { textures = authored }
            let value = newValue.map(SceneJSONValue.string) ?? .null
            if textures.isEmpty { textures = [value] } else { textures[0] = value }
            pass["textures"] = .array(textures)
        }
    }

    public func string(_ key: String) -> String? { pass[key]?.stringValue }

    public mutating func setString(_ value: String?, for key: String) {
        pass[key] = value.map(SceneJSONValue.string)
    }

    public func constant(_ key: String) -> SceneJSONValue? {
        pass["constants"]?[key]
    }

    public mutating func setConstant(_ value: SceneJSONValue?, for key: String) {
        var constants: [String: SceneJSONValue] = [:]
        if case .object(let authored)? = pass["constants"] { constants = authored }
        constants[key] = value
        pass["constants"] = constants.isEmpty ? nil : .object(constants)
    }
}
