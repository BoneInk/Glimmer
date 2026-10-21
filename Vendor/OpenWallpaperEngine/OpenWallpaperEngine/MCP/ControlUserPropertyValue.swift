import Foundation
import OWEControlProtocol
import OWESceneEditing

/// A user property's new value from the control channel, checked against the property as WE's
/// Details panel would accept it, and written the way the panel stores it (a WE value string).
enum ControlUserPropertyValue {
    /// The stored string for `value`, or an `invalidParams` error saying what the property takes.
    static func stored(_ value: JSONValue, for property: ControlUserProperty) throws -> String {
        switch property.type {
        case "slider": return try slider(value, property)
        case "bool": return try bool(value, property)
        case "combo": return try combo(value, property)
        case "color": return try color(value, property)
        case "textinput": return try text(value, property)
        case "file", "directory", "texture": return try path(value, property)
        default:
            throw invalid(property, "is a \(property.type.isEmpty ? "text" : property.type) row, which can't be set")
        }
    }

    private static func slider(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        let number: Double
        switch value {
        case .number(let given): number = given
        case .string(let text):
            guard let parsed = Double(text.trimmingCharacters(in: .whitespaces)) else { throw invalid(property, "takes a number") }
            number = parsed
        default: throw invalid(property, "takes a number")
        }
        let range = "\(format(property.minimum)) to \(format(property.maximum))"
        guard number.isFinite, number >= property.minimum, number <= property.maximum else {
            throw invalid(property, "takes a number from \(range)")
        }
        guard property.fraction || number.rounded() == number else {
            throw invalid(property, "takes a whole number from \(range)")
        }
        return format(number)
    }

    private static func bool(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        switch value {
        case .bool(let flag): return flag ? "true" : "false"
        case .string(let text) where ["true", "false"].contains(text.lowercased()): return text.lowercased()
        case .number(let number) where number == 0 || number == 1: return number == 1 ? "true" : "false"
        default: throw invalid(property, "takes true or false")
        }
    }

    private static func combo(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        let text: String
        switch value {
        case .string(let given): text = given
        case .number(let number): text = format(number)
        case .bool(let flag): text = flag ? "true" : "false"
        default: throw invalid(property, "takes one of its options")
        }
        if property.options.contains(where: { $0.value == text }) || property.editable { return text }
        // A label works too, as the panel shows labels.
        if let option = property.options.first(where: { $0.label.caseInsensitiveCompare(text) == .orderedSame }) {
            return option.value
        }
        let options = property.options.map { "\"\($0.value)\" (\($0.label))" }.joined(separator: ", ")
        throw invalid(property, "takes one of \(options)")
    }

    /// WE's colour: three numbers 0…1 separated by spaces; `#rrggbb` and `[r, g, b]` are converted.
    private static func color(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        var components: [Double]?
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), trimmed.count == 7, let rgb = Int(trimmed.dropFirst(), radix: 16) {
                components = [Double((rgb >> 16) & 0xFF) / 255, Double((rgb >> 8) & 0xFF) / 255, Double(rgb & 0xFF) / 255]
            } else {
                let parts = SceneVector.tokens(trimmed).map { Double($0) }
                if parts.count == 3, parts.allSatisfy({ $0 != nil }) { components = parts.compactMap { $0 } }
            }
        case .array(let items):
            let parts = items.compactMap(\.doubleValue)
            if parts.count == 3, items.count == 3 { components = parts }
        default:
            break
        }
        guard let components, components.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw invalid(property, "takes a colour as \"r g b\" with each 0 to 1, or #rrggbb")
        }
        return components.map(format).joined(separator: " ")
    }

    private static func text(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        switch value {
        case .string(let text): return text
        case .number(let number): return format(number)
        case .bool(let flag): return flag ? "true" : "false"
        default: throw invalid(property, "takes text")
        }
    }

    private static func path(_ value: JSONValue, _ property: ControlUserProperty) throws -> String {
        guard let path = value.stringValue else { throw invalid(property, "takes an absolute path") }
        guard !path.isEmpty else { return "" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard url.path.hasPrefix("/"), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw invalid(property, "takes the absolute path of an existing \(property.type == "directory" ? "folder" : "file")")
        }
        guard isDirectory.boolValue == (property.type == "directory") else {
            throw invalid(property, property.type == "directory" ? "takes a folder, not a file" : "takes a file, not a folder")
        }
        return url.path
    }

    private static func invalid(_ property: ControlUserProperty, _ reason: String) -> ControlError {
        ControlError(.invalidParams, "The property \"\(property.key)\"\(property.title.isEmpty ? "" : " (\(property.title))") \(reason).")
    }

    /// A number as WE writes it: whole numbers without a fraction.
    static func format(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }
}
