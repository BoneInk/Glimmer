import Foundation

/// Writes JSON exactly as WE writes its files: JsonCpp's styled stream writer with a tab
/// indentation, `" : "` after a name, members sorted by name, an object or a non-empty array of
/// objects on lines of their own, a short array of scalars on one line (`[ a, b ]`, under JsonCpp's
/// right margin of 74) and no newline at the end. WE's two writers differ in a few spellings,
/// which `Style` holds:
/// - `generated`, the files it generates (scene.json and project.json in its mobile packages):
///   reals with 8 significant digits (`%.8g`, `.0` added to whole numbers: `0.64999998`, `2.0`),
///   non-ASCII characters escaped as `\uxxxx`, and Windows line ends. Checked byte for byte
///   against WE 2.8.42's mobile export of a Workshop scene (`MobilePackageTests`).
/// - `editor`, the files its editor writes into a project (a new effect's `effect.json` and
///   material, `CustomEffect`): reals as their shortest text, other characters as they are, and
///   `\n` line ends.
public enum WEJSONWriter {
    /// JsonCpp's `rightMargin_`.
    public static let rightMargin = 74
    public static let precision = 8

    /// How a writer spells what JsonCpp leaves to its settings.
    public struct Style: Sendable {
        /// Characters from U+0080 as `\uxxxx` escapes (surrogate pairs past U+FFFF), else as they are.
        public var escapesNonASCII: Bool
        /// Reals at `precision` significant digits, else as Swift's shortest text (`0.5`, `1e+15`).
        public var jsonCppReals: Bool
        /// Written for each line break.
        public var lineEnd: String

        /// WE's generated files (its mobile export).
        public static let generated = Style(escapesNonASCII: true, jsonCppReals: true, lineEnd: "\r\n")
        /// The files WE's editor writes into a project.
        public static let editor = Style(escapesNonASCII: false, jsonCppReals: false, lineEnd: "\n")
    }

    public static func string(_ document: WEJSONDocument, style: Style = .generated) -> String {
        var writer = Writer(style: style)
        writer.write(document)
        return style.lineEnd == "\n" ? writer.output : writer.output.replacingOccurrences(of: "\n", with: style.lineEnd)
    }

    public static func data(_ document: WEJSONDocument, style: Style = .generated) -> Data {
        Data(string(document, style: style).utf8)
    }

    /// A real as JsonCpp writes it at `precision` significant digits.
    public static func real(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        var text = String(format: "%.\(precision)g", value)
        if !text.contains("."), !text.contains("e") { text += ".0" }
        return text
    }

    /// JsonCpp's `valueToQuotedString`: quotes, backslashes and control characters escaped, and
    /// with `escapesNonASCII` every character from U+0080.
    public static func quoted(_ string: String, escapesNonASCII: Bool = true) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{8}": result += "\\b"
            case "\u{C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                let value = scalar.value
                if value < 0x20 || (escapesNonASCII && (0x80..<0x10000).contains(value)) {
                    result += String(format: "\\u%04x", value)
                } else if escapesNonASCII && value >= 0x10000 {
                    let offset = value - 0x10000
                    result += String(format: "\\u%04x\\u%04x", 0xD800 + (offset >> 10), 0xDC00 + (offset & 0x3FF))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    public static func scalar(_ document: WEJSONDocument, style: Style = .generated) -> String? {
        switch document {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .unsigned(let value): return String(value)
        case .real(let value): return style.jsonCppReals ? real(value) : "\(value)"
        case .string(let value): return quoted(value, escapesNonASCII: style.escapesNonASCII)
        case .array, .object: return nil
        }
    }

    /// JsonCpp's `BuiltStyledStreamWriter`, its state as it keeps it.
    private struct Writer {
        let style: Style
        var output = ""
        var indentation = ""
        var indented = true

        init(style: Style) { self.style = style }

        mutating func newLine() { output += "\n" + indentation }

        mutating func writeWithIndent(_ text: String) {
            if !indented { newLine() }
            output += text
            indented = false
        }

        mutating func write(_ document: WEJSONDocument) {
            switch document {
            case .object(let members):
                guard !members.isEmpty else { output += "{}"; return }
                writeWithIndent("{")
                indentation += "\t"
                let names = members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
                for (index, name) in names.enumerated() {
                    writeWithIndent(WEJSONWriter.quoted(name, escapesNonASCII: style.escapesNonASCII))
                    output += " : "
                    write(members[name] ?? .null)
                    if index + 1 < names.count { output += "," }
                }
                indentation.removeLast()
                writeWithIndent("}")
            case .array(let elements):
                guard !elements.isEmpty else { output += "[]"; return }
                if let line = singleLine(elements) {
                    output += "[ " + line.joined(separator: ", ") + " ]"
                    return
                }
                writeWithIndent("[")
                indentation += "\t"
                for (index, element) in elements.enumerated() {
                    if let text = WEJSONWriter.scalar(element, style: style) {
                        writeWithIndent(text)
                    } else {
                        if !indented { newLine() }
                        indented = true
                        write(element)
                        indented = false
                    }
                    if index + 1 < elements.count { output += "," }
                }
                indentation.removeLast()
                writeWithIndent("]")
            default:
                output += WEJSONWriter.scalar(document, style: style) ?? "null"
            }
        }

        /// The elements written on one line, or nil when JsonCpp puts them on lines of their own
        /// (`isMultilineArray`). An element's length is its bytes; text the writer leaves
        /// unescaped (`editor`) is measured in characters, as the editor's files always were.
        func singleLine(_ elements: [WEJSONDocument]) -> [String]? {
            guard elements.count * 3 < WEJSONWriter.rightMargin else { return nil }
            var texts: [String] = []
            var length = 4 + (elements.count - 1) * 2
            for element in elements {
                switch element {
                case .array(let inner) where !inner.isEmpty: return nil
                case .object(let inner) where !inner.isEmpty: return nil
                default: break
                }
                var writer = Writer(style: style)
                writer.write(element)
                texts.append(writer.output)
                length += style.escapesNonASCII ? writer.output.utf8.count : writer.output.count
            }
            return length < WEJSONWriter.rightMargin ? texts : nil
        }
    }
}
