import Foundation

/// One `general.properties` entry of a project.json, read the way WE's browse sidebar reads it
/// (`ui/dist/scripts/scripts.js`, the `property.type=='slider'` row and
/// `EditorUserPropertyDetailsModalCtrl`).
struct UserPropertyDefinition: Equatable {
    struct Option: Equatable {
        /// As authored: plain text or a WE localisation key.
        let label: String
        let value: String
    }

    /// WE's editor creates a slider as `min: 0, max: 1` (`EditorUserPropertyDetailsModalCtrl`),
    /// the range a slider without them gets.
    static let defaultSliderRange: ClosedRange<Double> = 0...1

    let key: String
    /// Lower-cased; untyped entries are WE's text rows.
    let type: String
    /// The `text` label as authored (plain, HTML or a localisation key).
    let text: String
    /// nil when not authored.
    let order: Int?
    /// The authored `value` as a WE value string; nil when not authored.
    let value: String?
    let minimum: Double
    let maximum: Double
    /// Slider step: the authored `step`, else 1 (WE's slider uses `step: property.step || 1`).
    let step: Double
    /// Slider precision: the authored `precision`, else 1 (`precision: property.precision || 1`).
    /// WE stores one more than the decimals it shows (the editor saves `precision + 1`).
    let precision: Int
    /// `fraction`: false means whole numbers. Absent means true, as WE's editor creates sliders.
    let fraction: Bool
    let options: [Option]
    let condition: String?
    let editable: Bool

    init(key: String, raw: [String: Any]) {
        self.key = key
        type = (raw["type"] as? String)?.lowercased() ?? "text"
        text = raw["text"] as? String ?? ""
        order = (raw["order"] as? NSNumber)?.intValue
        value = raw["value"].map(sceneUserPropertyString)
        minimum = (raw["min"] as? NSNumber)?.doubleValue ?? Self.defaultSliderRange.lowerBound
        maximum = (raw["max"] as? NSNumber)?.doubleValue ?? Self.defaultSliderRange.upperBound
        let authoredStep = (raw["step"] as? NSNumber)?.doubleValue ?? 0
        step = authoredStep > 0 ? authoredStep : 1
        let authoredPrecision = (raw["precision"] as? NSNumber)?.intValue ?? 0
        precision = authoredPrecision > 0 ? authoredPrecision : 1
        fraction = (raw["fraction"] as? NSNumber)?.boolValue ?? true
        options = (raw["options"] as? [[String: Any]] ?? []).compactMap { option in
            guard let label = option["label"] as? String, let value = option["value"] else { return nil }
            return Option(label: label, value: sceneUserPropertyString(value))
        }
        condition = raw["condition"] as? String
        editable = (raw["editable"] as? NSNumber)?.boolValue ?? false
    }

    /// Every entry of a project.json, keyed as authored.
    static func all(projectJSON root: [String: Any]) -> [UserPropertyDefinition] {
        let raw = (root["general"] as? [String: Any])?["properties"] as? [String: [String: Any]] ?? [:]
        return raw.map { UserPropertyDefinition(key: $0.key, raw: $0.value) }
    }

    /// The value the sidebar starts from: the authored one, else a combo's first option, else
    /// false for a bool. A user shortcut starts unbound whatever the author wrote: only the user
    /// binds one (`UserShortcutBinding`).
    var defaultValue: String {
        if type == SceneScriptUserProperties.Property.userShortcutType { return "" }
        return value ?? (type == "combo" ? options.first?.value : nil) ?? (type == "bool" ? "false" : "")
    }

    var sliderFormat: UserPropertySliderFormat {
        UserPropertySliderFormat(minimum: minimum, maximum: maximum, fraction: fraction, step: step, precision: precision)
    }
}
