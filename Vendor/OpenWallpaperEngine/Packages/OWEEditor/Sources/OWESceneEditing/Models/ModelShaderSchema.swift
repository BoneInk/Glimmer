import Foundation

/// What a model material's shader lets WE's Advanced Texture Settings change, read from its
/// annotations as WE's editor reads them: `// [COMBO] {…}` lines, and the `// {…}` after a
/// `uniform` (a sampler's label, combo and default; a constant's `material` key, label, range
/// and default). `generic4`, `foliage4`, `fur4` and `chroma4` are WE's model shaders
/// (docs/model-import.md).
public struct ModelShaderSchema: Equatable, Sendable {
    public struct Combo: Equatable, Sendable, Identifiable {
        public var name: String
        /// WE's label key (`ui_editor_properties_lighting`).
        public var label: String
        public var defaultValue: Int
        /// Choices by label key; empty for an on/off combo.
        public var options: [(label: String, value: Int)]
        /// Combos that must have these values for this one to apply.
        public var requirements: [String: Int]
        public var id: String { name }

        public static func == (lhs: Combo, rhs: Combo) -> Bool {
            lhs.name == rhs.name && lhs.label == rhs.label && lhs.defaultValue == rhs.defaultValue
                && lhs.options.map(\.label) == rhs.options.map(\.label) && lhs.options.map(\.value) == rhs.options.map(\.value)
                && lhs.requirements == rhs.requirements
        }
    }

    public struct Texture: Equatable, Sendable, Identifiable {
        /// The sampler's index (`g_Texture<slot>`), its place in the material's `textures`.
        public var slot: Int
        public var label: String
        public var defaultTexture: String?
        /// The combo its texture turns on (`NORMALMAP`, `PBRMASKS`).
        public var combo: String?
        /// The channels of a packed map (`PBRMASKS`: metallic, roughness, reflection, emissive), by label.
        public var components: [(label: String, combo: String)]
        public var requirements: [String: Int]
        public var id: Int { slot }

        public static func == (lhs: Texture, rhs: Texture) -> Bool {
            lhs.slot == rhs.slot && lhs.label == rhs.label && lhs.defaultTexture == rhs.defaultTexture && lhs.combo == rhs.combo
                && lhs.components.map(\.label) == rhs.components.map(\.label) && lhs.requirements == rhs.requirements
        }
    }

    public struct Constant: Equatable, Sendable, Identifiable {
        /// The key in the material's `constantshadervalues`.
        public var key: String
        public var label: String
        /// 1 to 4 numbers.
        public var defaultValue: [Double]
        public var minimum: Double
        public var maximum: Double
        public var isColor: Bool
        /// WE's group label key (`ui_editor_properties_material`); nil for the top.
        public var group: String?
        public var id: String { key }
    }

    public var combos: [Combo] = []
    public var textures: [Texture] = []
    public var constants: [Constant] = []

    public init(combos: [Combo] = [], textures: [Texture] = [], constants: [Constant] = []) {
        self.combos = combos
        self.textures = textures
        self.constants = constants
    }

    /// WE's model shaders, as Advanced Texture Settings offers them.
    public static let modelShaders = ["generic4", "foliage4", "fur4", "chroma4"]

    /// The schema of `shader` from its sources (`shaders/<shader>.frag` and `.vert`), read
    /// with `read`; nil when neither can be read.
    public static func load(_ shader: String, read: (String) -> Data?) -> ModelShaderSchema? {
        let sources = ["frag", "vert"].compactMap { read("shaders/\(shader).\($0)").map { String(decoding: $0, as: UTF8.self) } }
        guard !sources.isEmpty else { return nil }
        var schema = ModelShaderSchema()
        for source in sources { schema.merge(parse(source)) }
        return schema
    }

    mutating func merge(_ other: ModelShaderSchema) {
        for combo in other.combos where !combos.contains(where: { $0.name == combo.name }) { combos.append(combo) }
        for texture in other.textures where !textures.contains(where: { $0.slot == texture.slot }) { textures.append(texture) }
        for constant in other.constants where !constants.contains(where: { $0.key == constant.key }) { constants.append(constant) }
        textures.sort { $0.slot < $1.slot }
    }

    /// The annotations of one shader source.
    public static func parse(_ source: String) -> ModelShaderSchema {
        var schema = ModelShaderSchema()
        for raw in source.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("// [COMBO]"), let json = object(String(line.dropFirst("// [COMBO]".count))),
               let name = json["combo"] as? String {
                var options: [(String, Int)] = []
                if let list = json["options"] as? [String: Any] {
                    options = list.compactMap { key, value in (value as? NSNumber).map { (key, $0.intValue) } }.sorted { $0.1 < $1.1 }
                }
                schema.combos.append(Combo(name: name, label: json["material"] as? String ?? name,
                                           defaultValue: (json["default"] as? NSNumber)?.intValue ?? 0, options: options,
                                           requirements: requirements(json["require"])))
                continue
            }
            guard line.hasPrefix("uniform "), let comment = line.range(of: "//"),
                  let json = object(String(line[comment.upperBound...])) else { continue }
            let declaration = line[..<comment.lowerBound].split(whereSeparator: { $0 == " " || $0 == ";" })
            guard declaration.count >= 3 else { continue }
            let type = String(declaration[1]), name = String(declaration[2])
            if type.hasPrefix("sampler2D") {
                guard json["hidden"] as? Bool != true, name.hasPrefix("g_Texture"), let slot = Int(name.dropFirst("g_Texture".count)) else { continue }
                let components = (json["components"] as? [[String: Any]] ?? []).compactMap { component -> (String, String)? in
                    guard let label = component["label"] as? String, let combo = component["combo"] as? String else { return nil }
                    return (label, combo)
                }
                schema.textures.append(Texture(slot: slot, label: json["label"] as? String ?? json["material"] as? String ?? name,
                                               defaultTexture: json["default"] as? String, combo: json["combo"] as? String,
                                               components: components, requirements: requirements(json["require"])))
            } else if let key = json["material"] as? String {
                let count = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4][type] ?? 0
                guard count > 0 else { continue }
                var value: [Double] = []
                if let number = json["default"] as? NSNumber { value = [number.doubleValue] }
                if let text = json["default"] as? String { value = text.split(separator: " ").compactMap { Double($0) } }
                if value.count != count { value = Array(repeating: value.first ?? 0, count: count) }
                let range = json["range"] as? [NSNumber]
                schema.constants.append(Constant(key: key, label: json["label"] as? String ?? key, defaultValue: value,
                                                 minimum: range?.first?.doubleValue ?? 0, maximum: range?.last?.doubleValue ?? 1,
                                                 isColor: (json["type"] as? String) == "color", group: json["group"] as? String))
            }
        }
        return schema
    }

    static func object(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func requirements(_ value: Any?) -> [String: Int] {
        (value as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    /// Whether `combo`'s requirements hold for these combo values.
    public static func holds(_ requirements: [String: Int], values: (String) -> Int) -> Bool {
        requirements.allSatisfy { values($0.key) == $0.value }
    }
}
