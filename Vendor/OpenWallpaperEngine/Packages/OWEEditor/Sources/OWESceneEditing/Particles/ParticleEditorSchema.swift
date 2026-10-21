import Foundation

/// WE's particle editor as `wallpaperui.exe` builds it (docs/we-particle-editor-schema.json): every
/// component the editor offers (emitters, initializers, operators, renderers, a child, a control
/// point, the system itself and a layer's instance override), each with its fields in panel order:
/// the JSON key, the control (`Field.Kind`), its range, the value the editor writes when the
/// component is added, and when the panel shows it.
public struct ParticleEditorSchema: Sendable {
    /// Where a component lives: a list of the particle JSON, its root, or the scene object.
    public enum Section: String, CaseIterable, Sendable {
        case emitter, initializer, `operator`, renderer, children, controlpoint
        /// The particle JSON's root (`maxcount`, `starttime`, `flags`, …).
        case system = "_system"
        /// The scene object's `instanceoverride`.
        case instanceoverride

        /// The particle JSON's list for the section; nil for the root and the instance override.
        public var listKey: String? {
            switch self {
            case .system, .instanceoverride: return nil
            default: return rawValue
            }
        }

        /// The sections that are lists of the particle JSON, in WE's panel order.
        public static let lists: [Section] = [.emitter, .initializer, .operator, .renderer, .children, .controlpoint]

        /// A list whose items are typed by `name` (the others hold one kind of item).
        public var isTyped: Bool { self == .emitter || self == .initializer || self == .operator || self == .renderer }
    }

    public struct Option: Hashable, Sendable {
        public let label: String
        public let value: SceneJSONValue
    }

    public struct Field: Identifiable, Hashable, Sendable {
        public enum Kind: String, Sendable {
            /// A number box without a range.
            case number
            /// A float slider with a number box; `slider` a free one, `sliderint` whole numbers.
            case slider, sliderint
            /// A boolean of its own key; `checkboxbit` one bit of `flags`.
            case checkbox, checkboxbit
            /// Per-component number boxes, stored as WE's `"x y z"` string.
            case vec2, vec3
            /// A colour picker (`normalized`: 0–1, else 0–255 per channel), a hue (0–1), a list of colours.
            case color, hue, colorlist
            /// A choice among `options`.
            case combo
        }

        /// The schema's own name: the JSON key, or `flags&0x…` for a flag.
        public let id: String
        /// The JSON key the field reads and writes.
        public let key: String
        /// For `checkboxbit`: the bit of `flags`.
        public let bit: Int?
        public let kind: Kind
        /// WE's English label, which names the field in the editor's catalog.
        public let label: String
        public let minimum: Double?
        public let maximum: Double?
        public let isInteger: Bool
        /// Component names of a vector (`X`, `Y`, `Z`; `Start`, `End`; `Width`, `Depth`).
        public let components: [String]
        /// A vector shown in degrees and stored in radians.
        public let isAngle: Bool
        /// A colour stored 0–1 (else 0–255).
        public let isNormalized: Bool
        public let options: [Option]
        /// When the panel shows the field; for a field with `vectorType`, when it is a number
        /// rather than a vector.
        public let condition: ParticleFieldCondition
        /// The value WE's editor writes when the component is added, in a 2D scene, and in a 3D
        /// one when it differs.
        public let addDefault: SceneJSONValue?
        public let addDefault3D: SceneJSONValue?
        /// The heading WE groups the field under (`Count`, `Speed`, `Audio response`).
        public let group: String?
        /// A number field that is a vector of this kind while `condition` is false (the remap ranges).
        public let vectorType: Kind?
        /// WE's warning shown with the field.
        public let hint: String?

        /// The value the editor writes on add for a 2D (`pixelUnits`) or 3D scene.
        public func defaultValue(pixelUnits: Bool) -> SceneJSONValue? {
            pixelUnits ? addDefault : (addDefault3D ?? addDefault)
        }

        /// The control the field shows for the component's `values`: its own, or its vector form
        /// for a remap range whose value is a vector.
        public func effectiveKind(in values: ParticleFieldCondition.Values) -> Kind {
            guard let vectorType else { return kind }
            return condition.evaluate(values) ? kind : vectorType
        }

        /// Whether the panel shows the field (a field with `vectorType` always shows).
        public func isVisible(in values: ParticleFieldCondition.Values) -> Bool {
            vectorType != nil || condition.evaluate(values)
        }
    }

    public struct Component: Identifiable, Hashable, Sendable {
        /// The schema's key: `operator:movement`, `children`, `_system`.
        public let id: String
        public let section: Section
        /// The item's `name` (`movement`); nil for the untyped sections.
        public let name: String?
        /// WE's English name of the component.
        public let title: String
        /// Offered by WE's add dialog (WE leaves out the legacy `vortex` and `collisionbox`).
        public let isAddable: Bool
        public let fields: [Field]

        public func field(_ id: String) -> Field? { fields.first { $0.id == id } }
    }

    public let components: [Component]

    public init(data: Data) throws {
        let root = try OrderedJSON.parse(data)
        var components: [Component] = []
        for (key, entry) in root.pairs where key != "_meta" {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard let section = Section(rawValue: parts[0]) else { continue }
            let name = parts.count > 1 ? parts[1] : nil
            let fields = entry["fields"]?.pairs.compactMap { Self.field(id: $0.key, $0.value) } ?? []
            components.append(Component(id: key, section: section, name: name,
                                        title: Self.title(of: key, displayName: entry["display_name"]?.stringValue),
                                        isAddable: !Self.legacy.contains(key), fields: fields))
        }
        guard !components.isEmpty else { throw OrderedJSON.ParseError.unexpected(offset: 0) }
        self.components = components
    }

    public func components(in section: Section) -> [Component] {
        components.filter { $0.section == section }
    }

    /// The component an item of `section` is: by its `name` for the typed lists.
    public func component(_ section: Section, name: String? = nil) -> Component? {
        if section.isTyped {
            guard let name = name?.lowercased() else { return nil }
            return components.first { $0.section == section && $0.name == name }
        }
        return components.first { $0.section == section }
    }

    /// The components WE's add dialog doesn't offer: the legacy vortex, and the collision box,
    /// which has no name in WE's locale (and does nothing at run time).
    static let legacy: Set<String> = ["operator:vortex", "operator:collisionbox"]

    /// WE's English name of a component. The schema records some as the raw locale key WE shows
    /// (or a note); those read as WE's own wording would.
    static func title(of key: String, displayName: String?) -> String {
        if let title = titles[key] { return title }
        return displayName ?? key
    }

    static let titles: [String: String] = [
        "initializer:mapsequencearoundcontrolpoint": "Map sequence around control point",
        "initializer:mapsequencebetweencontrolpoints": "Map sequence between control points",
        "operator:controlpointattract": "Control point attract",
        "operator:collisionquad": "Collision quad",
        "operator:collisionbox": "Collision box",
        "operator:vortex": "Vortex (legacy)",
        "children": "Child",
        "controlpoint": "Control point",
        "_system": "System",
        "instanceoverride": "Instance override",
    ]

    static func field(id: String, _ entry: OrderedJSON) -> Field? {
        guard let kind = entry["type"]?.stringValue.flatMap(Field.Kind.init(rawValue:)),
              let label = entry["label"]?.stringValue else { return nil }
        let key = id.split(separator: "&").first.map(String.init) ?? id
        let options = entry["options"]?.arrayValue?.compactMap { option -> Option? in
            guard let label = option["label"]?.stringValue, let value = option["value"] else { return nil }
            return Option(label: label, value: value.sceneValue)
        } ?? []
        return Field(id: id, key: key, bit: entry["bit"]?.doubleValue.map { Int($0) }, kind: kind, label: label,
                     minimum: entry["min"]?.doubleValue, maximum: entry["max"]?.doubleValue,
                     isInteger: entry["integer"]?.boolValue == true || kind == .sliderint,
                     components: entry["components"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                     isAngle: entry["mode"]?.stringValue == "angle",
                     isNormalized: entry["normalized"]?.boolValue ?? (kind == .hue),
                     options: options,
                     condition: ParticleFieldCondition(expression: entry["condition"]?.stringValue),
                     addDefault: entry["add_default"].map { Self.addDefault($0.sceneValue, kind: kind) },
                     addDefault3D: entry["add_default_3d"].map { Self.addDefault($0.sceneValue, kind: kind) },
                     group: entry["group"]?.stringValue,
                     vectorType: entry["vector_type"]?.stringValue.flatMap(Field.Kind.init(rawValue:)),
                     hint: entry["hint"]?.stringValue)
    }

    /// The schema writes a colour list's default as its one colour; the JSON holds a list.
    static func addDefault(_ value: SceneJSONValue, kind: Field.Kind) -> SceneJSONValue {
        if kind == .colorlist, case .string = value { return .array([value]) }
        return value
    }
}

/// When WE's panel shows a field: the JavaScript conditions of the schema, read into the few forms
/// they take (`checkFlags(4)`, `checkValue('transformfunction', 'none')`,
/// `findProperty('audioprocessingmode').value>0`, `checkRemapValueIsScalar('input')`, …).
public indirect enum ParticleFieldCondition: Hashable, Sendable {
    case always
    case not(ParticleFieldCondition)
    /// A bit of the component's `flags`.
    case flag(Int)
    /// A key's value equals this one.
    case equals(String, SceneJSONValue)
    case greaterThanZero(String)
    /// A key's value is true.
    case truthy(String)
    /// The remap `input`/`output` names a scalar value (else a vector).
    case remapScalar(String)
    /// The remap value reads a control point, or two (`positionbetweentwocontrolpoints`).
    case remapControlPoint(String)
    case remapSecondControlPoint(String)

    /// A component's values as the panel reads them: the authored value, else the default the
    /// editor writes.
    public struct Values {
        public let lookup: (String) -> SceneJSONValue?

        public init(_ lookup: @escaping (String) -> SceneJSONValue?) {
            self.lookup = lookup
        }

        public subscript(key: String) -> SceneJSONValue? { lookup(key) }
    }

    /// The remap values that are scalars: the particle's own numbers and the clocks
    /// (`ParticleProgramEncoding.remapValues`, WE's `remapValues` 0…12); the rest are vectors.
    public static let scalarRemapValues: Set<String> = [
        "lifetimefraction", "maxlifetime", "size", "opacity", "speed", "rotation", "angularspeed",
        "distancetocontrolpoint", "positionbetweentwocontrolpoints", "runtime", "timeofday",
        "particlesystemtime", "layertime",
    ]

    public static let controlPointRemapValues: Set<String> = [
        "distancetocontrolpoint", "positionbetweentwocontrolpoints", "controlpoint", "deltatocontrolpoint",
        "directiontocontrolpoint",
    ]

    /// Reads a schema condition; text it doesn't know (a note) shows the field.
    public init(expression: String?) {
        guard var text = expression?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            self = .always
            return
        }
        // Notes follow the expression: "checkFlags(4) (vec3 otherwise)".
        if let note = text.range(of: " (") { text = String(text[..<note.lowerBound]) }
        if text.hasPrefix("!") {
            let inner = ParticleFieldCondition(expression: String(text.dropFirst()))
            self = inner == .always ? .always : .not(inner)
            return
        }
        func arguments(_ prefix: String) -> [String]? {
            guard text.hasPrefix(prefix + "("), text.hasSuffix(")") else { return nil }
            let inner = text.dropFirst(prefix.count + 1).dropLast()
            return inner.split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            }
        }
        if let args = arguments("checkFlags"), let bit = args.first.flatMap({ Int($0) }) {
            self = .flag(bit)
        } else if let args = arguments("checkBit"), args.count == 2, let bit = Int(args[1]) {
            // `checkBit(findProperty('flags').value, 4)`, `checkBit(pList[7].value, 1)` (a child's flags).
            self = .flag(bit)
        } else if let args = arguments("checkValue"), args.count == 2 {
            self = .equals(args[0], Self.literal(args[1]))
        } else if let args = arguments("checkRemapValueIsScalar"), let key = args.first {
            self = .remapScalar(key)
        } else if let args = arguments("checkRemapValueIsControlPoint2"), let key = args.first {
            self = .remapSecondControlPoint(key)
        } else if let args = arguments("checkRemapValueIsControlPoint"), let key = args.first {
            self = .remapControlPoint(key)
        } else if text == "pList[6].value==='sequence'" {
            // The system panel's animation mode.
            self = .equals("animationmode", .string("sequence"))
        } else if let match = Self.propertyComparison(text) {
            self = match
        } else {
            self = .always
        }
    }

    /// `findProperty('key').value>0`, `…=='bounce'`, `…!='screen'`, or `…value` alone.
    private static func propertyComparison(_ text: String) -> ParticleFieldCondition? {
        let prefix = "findProperty('"
        guard text.hasPrefix(prefix), let close = text.range(of: "').value") else { return nil }
        let key = String(text[text.index(text.startIndex, offsetBy: prefix.count)..<close.lowerBound])
        let rest = text[close.upperBound...].trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return .truthy(key) }
        if rest.hasPrefix(">0") { return .greaterThanZero(key) }
        if rest.hasPrefix("!=") {
            return .not(.equals(key, literal(String(rest.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "= '\"")))))
        }
        if rest.hasPrefix("==") {
            return .equals(key, literal(String(rest.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "= '\""))))
        }
        return nil
    }

    private static func literal(_ text: String) -> SceneJSONValue {
        if let number = Double(text) { return .number(number) }
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        return .string(text)
    }

    public func evaluate(_ values: Values) -> Bool {
        switch self {
        case .always:
            return true
        case .not(let inner):
            return !inner.evaluate(values)
        case .flag(let bit):
            let flags = Int(values["flags"]?.doubleValue ?? 0)
            return flags & bit != 0
        case .equals(let key, let expected):
            guard let value = values[key] else { return false }
            if let left = value.stringValue, let right = expected.stringValue { return left.lowercased() == right.lowercased() }
            if let left = value.doubleValue, let right = expected.doubleValue { return left == right }
            return value == expected
        case .greaterThanZero(let key):
            return (values[key]?.doubleValue ?? 0) > 0
        case .truthy(let key):
            return values[key]?.boolValue ?? false
        case .remapScalar(let key):
            return Self.scalarRemapValues.contains(values[key]?.stringValue?.lowercased() ?? "")
        case .remapControlPoint(let key):
            return Self.controlPointRemapValues.contains(values[key]?.stringValue?.lowercased() ?? "")
        case .remapSecondControlPoint(let key):
            return values[key]?.stringValue?.lowercased() == "positionbetweentwocontrolpoints"
        }
    }
}
