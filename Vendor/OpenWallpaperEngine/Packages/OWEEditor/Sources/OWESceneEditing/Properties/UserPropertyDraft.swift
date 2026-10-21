import Foundation

/// One `general.properties` entry of project.json as the editor authors it: the fields WE's
/// editor sets (`EditorUserPropertyDetailsModalCtrl`: type, label, default, slider range, step and
/// precision, combo options, condition, order) plus every other authored key kept as it was, so a
/// property the editor doesn't know all of round-trips unchanged.
public struct UserPropertyDraft: Codable, Hashable, Sendable, Identifiable {
    /// project.json `type`. Unknown types are kept as authored.
    public struct Kind: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue.lowercased() }

        /// Coded as its name, as project.json writes it.
        public init(from decoder: Decoder) throws {
            self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }

        public static let bool = Kind(rawValue: "bool")
        public static let slider = Kind(rawValue: "slider")
        public static let combo = Kind(rawValue: "combo")
        public static let color = Kind(rawValue: "color")
        public static let textInput = Kind(rawValue: "textinput")
        public static let file = Kind(rawValue: "file")
        public static let directory = Kind(rawValue: "directory")
        /// A user's own image or video in place of a texture (WE's "Texture"; the docs' `texture`),
        /// bound to a layer's texture slot by `usertextures`.
        public static let sceneTexture = Kind(rawValue: "scenetexture")
        /// A shortcut the user sets to a file, folder, website or command, opened from a script
        /// (`engine.openUserShortcut`); its icon can be bound to a texture slot.
        public static let userShortcut = Kind(rawValue: "usershortcut")
        /// Starts a group: the properties after it, up to the next group, fold under its label.
        public static let group = Kind(rawValue: "group")
        /// A label row with no value (an untyped entry reads as one, as WE's sidebar shows it).
        public static let text = Kind(rawValue: "text")

        /// The kinds the editor creates: WE's editor's scene types (`EditorUserPropertyDetailsModalCtrl`
        /// `typeOptions`), its web types (file, folder) and the label row.
        public static let authorable: [Kind] = [.bool, .slider, .color, .combo, .textInput, .file, .directory,
                                                .sceneTexture, .userShortcut, .group, .text]

        /// Whether a property of this kind has a value (a group and a label have none).
        public var hasValue: Bool { self != .text && self != .group }

        /// Whether the editor sets a default for it: a user texture and a shortcut start unset, as
        /// WE writes them (`value: ""`), and only the user picks them.
        public var hasDefault: Bool { hasValue && self != .sceneTexture && self != .userShortcut }

        /// Whether a texture slot is bound to it (`usertextures`) rather than a field (`user`).
        public var bindsTexture: Bool { self == .sceneTexture || self == .userShortcut }
    }

    /// A directory's `mode`: how a web wallpaper gets the folder's files.
    public enum FetchMode: String, CaseIterable, Sendable {
        /// `wallpaperRequestRandomFileForProperty` asks for one at a time (WE's default).
        case onDemand = "ondemand"
        /// `userDirectoryFilesAddedOrChanged` sends every file.
        case fetchAll = "fetchall"
    }

    /// A file's `fileType`: what the picker accepts.
    public enum FileType: String, CaseIterable, Sendable {
        case image, video
    }

    public struct Option: Codable, Hashable, Sendable {
        /// As authored: plain text or a WE localisation key.
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// The property's key, which bindings (`{"user": key}`) and conditions (`key.value`) name.
    public var key: String
    public var kind: Kind
    /// The label (`text`): plain, HTML or a localisation key.
    public var text: String
    /// The default (`value`); nil for a label row.
    public var value: SceneJSONValue?
    /// Slider `min`/`max`/`step`; nil when not authored (WE reads 0, 1 and 1).
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    /// Slider `precision` as WE stores it: one more than the decimals shown.
    public var precision: Int?
    /// Slider `fraction`: false means whole numbers; nil means true.
    public var fraction: Bool?
    public var options: [Option]
    /// `condition`: a JavaScript expression over the other properties (`clock.value == 1`); the
    /// property shows only while it holds.
    public var condition: String?
    /// Every other authored key (`index`, `fileType`, `mode`, `editable`, …), written back as it was.
    public var extra: [String: SceneJSONValue]

    public var id: String { key }

    public init(key: String, kind: Kind, text: String = "", value: SceneJSONValue? = nil,
                minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil, precision: Int? = nil,
                fraction: Bool? = nil, options: [Option] = [], condition: String? = nil,
                extra: [String: SceneJSONValue] = [:]) {
        self.key = key
        self.kind = kind
        self.text = text
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.precision = precision
        self.fraction = fraction
        self.options = options
        self.condition = condition
        self.extra = extra
    }

    /// The keys this type reads; everything else lands in `extra`.
    /// `index` is WE's numbering, written again from the list's order (`SceneAuthoring.applyProperties`).
    static let modelledKeys: Set<String> = ["type", "text", "value", "min", "max", "step", "precision", "fraction",
                                            "options", "condition", "order", "index"]

    /// Read from a project.json entry.
    public init(key: String, raw: [String: SceneJSONValue]) {
        self.key = key
        kind = Kind(rawValue: raw["type"]?.stringValue ?? "text")
        text = raw["text"]?.stringValue ?? ""
        value = raw["value"].flatMap { $0 == .null ? nil : $0 }
        minimum = raw["min"]?.doubleValue
        maximum = raw["max"]?.doubleValue
        step = raw["step"]?.doubleValue
        precision = raw["precision"]?.doubleValue.map { Int($0) }
        fraction = raw["fraction"]?.boolValue
        if case .array(let entries)? = raw["options"] {
            options = entries.compactMap { entry in
                guard let label = entry["label"]?.stringValue, let value = entry["value"] else { return nil }
                return Option(label: label, value: Self.text(of: value))
            }
        } else {
            options = []
        }
        let authoredCondition = raw["condition"]?.stringValue
        condition = authoredCondition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? authoredCondition : nil
        extra = raw.filter { !Self.modelledKeys.contains($0.key) }
    }

    /// The entry as project.json writes it, `order` being its place in the list.
    public func json(order: Int) -> [String: SceneJSONValue] {
        var entry = extra
        entry["type"] = .string(kind.rawValue)
        entry["text"] = .string(text)
        entry["order"] = .number(Double(order))
        if kind.hasValue, let value = writtenValue { entry["value"] = value }
        // WE writes an empty value for the kinds without one it shows (`EditorUserPropertyDetailsModalCtrl`).
        if kind == .group { entry["value"] = .string("") }
        if kind != .directory { entry["mode"] = nil }
        if kind != .file { entry["fileType"] = nil }
        if kind == .slider {
            entry["min"] = minimum.map(SceneJSONValue.number)
            entry["max"] = maximum.map(SceneJSONValue.number)
            entry["step"] = step.map(SceneJSONValue.number)
            entry["precision"] = precision.map { .number(Double($0)) }
            entry["fraction"] = fraction.map(SceneJSONValue.bool)
        }
        if kind == .combo {
            entry["options"] = .array(options.map { .object(["label": .string($0.label), "value": .string($0.value)]) })
        }
        if let condition, !condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry["condition"] = .string(condition)
        }
        return entry
    }

    /// The default in the form WE writes for the kind: a flag, a number, `"r g b"`, or text.
    var writtenValue: SceneJSONValue? {
        guard let value else { return nil }
        switch kind {
        case .bool: return value.boolValue.map(SceneJSONValue.bool) ?? .bool(false)
        case .slider: return value.doubleValue.map(SceneJSONValue.number) ?? .number(minimum ?? 0)
        default:
            if case .string = value { return value }
            return .string(Self.text(of: value))
        }
    }

    /// A value as the sidebar stores it ("true", "0.5", "1 0 0", "valueA").
    public static func text(of value: SceneJSONValue) -> String {
        switch value {
        case .string(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .number(let number): return SceneVector.format(number)
        case .null: return ""
        case .array(let values): return values.map(text(of:)).joined(separator: " ")
        case .object: return ""
        }
    }

    /// The value shown before the user changes it: the default, else a combo's first option,
    /// else false for a flag (as the app's sidebar starts).
    public var defaultText: String {
        if let value { return Self.text(of: value) }
        switch kind {
        case .combo: return options.first?.value ?? ""
        case .bool: return "false"
        case .slider: return SceneVector.format(minimum ?? 0)
        case .color: return "1 1 1"
        default: return ""
        }
    }

    /// A directory's fetch mode; nil when not authored (WE's web runtime then sends nothing).
    public var fetchMode: FetchMode? {
        get { extra["mode"]?.stringValue.flatMap(FetchMode.init(rawValue:)) }
        set { extra["mode"] = newValue.map { .string($0.rawValue) } }
    }

    /// A file's type; nil accepts any file.
    public var fileType: FileType? {
        get { extra["fileType"]?.stringValue.flatMap(FileType.init(rawValue:)) }
        set { extra["fileType"] = newValue.map { .string($0.rawValue) } }
    }

    /// The decimals a slider shows (`precision` minus one, at least 0).
    public var decimals: Int {
        get { max(0, (precision ?? 1) - 1) }
        set { precision = max(0, newValue) + 1 }
    }

    // MARK: New properties

    /// A new property of `kind` with WE's editor's starting values.
    public static func new(_ kind: Kind, key: String, text: String) -> UserPropertyDraft {
        var draft = UserPropertyDraft(key: key, kind: kind, text: text)
        switch kind {
        case .bool:
            draft.value = .bool(false)
        case .slider:
            draft.minimum = 0
            draft.maximum = 1
            draft.step = 0.01
            draft.precision = 3
            draft.value = .number(0.5)
        case .color:
            draft.value = .string("1 1 1")
        case .combo:
            draft.options = [Option(label: "Option 1", value: "1"), Option(label: "Option 2", value: "2")]
            draft.value = .string("1")
        case .textInput, .file, .sceneTexture, .userShortcut:
            draft.value = .string("")
        case .directory:
            draft.value = .string("")
            draft.fetchMode = .onDemand
        default:
            break
        }
        return draft
    }

    /// A key from `label` as WE's Add Property dialog makes one (`EditorUserPropertyDetailsModalCtrl`:
    /// `key.toLowerCase().replace(/\W+/g, "")`, a leading digit prefixed with `_`, nothing left
    /// giving `newproperty`; WE 2.8.0.42, capture 541: "Custom texture" is `customtexture`), not one
    /// of `taken` (a number is appended).
    public static func key(from label: String, taken: Set<String>) -> String {
        var base = String(label.lowercased().unicodeScalars.filter { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
        }.map(Character.init))
        if base.isEmpty { base = "newproperty" } else if base.first!.isNumber { base = "_" + base }
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)\(number)") { number += 1 }
        return "\(base)\(number)"
    }

    /// A key a condition or a binding can name: `[A-Za-z_$][A-Za-z0-9_$]*`.
    public static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, key.unicodeScalars.allSatisfy(\.isASCII) else { return false }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        let tail = head.union(.decimalDigits)
        return head.contains(first) && key.unicodeScalars.allSatisfy { tail.contains($0) }
    }
}
