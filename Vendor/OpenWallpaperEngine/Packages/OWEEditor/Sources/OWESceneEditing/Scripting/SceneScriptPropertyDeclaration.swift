import Foundation

/// A property a script declares with `createScriptProperties().addSlider({…})…finish()`, which
/// WE's editor shows under the script and stores in the field's `scriptproperties`.
public struct SceneScriptPropertyDeclaration: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case slider, checkbox, text, combo, color
    }

    public let name: String
    public let label: String
    public let kind: Kind
    /// The script's default (a combo's first option).
    public let value: SceneJSONValue?
    public let minimum: Double?
    public let maximum: Double?
    public let isInteger: Bool
    public let options: [(label: String, value: SceneJSONValue)]

    public var id: String { name }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.label == rhs.label && lhs.kind == rhs.kind && lhs.value == rhs.value
            && lhs.minimum == rhs.minimum && lhs.maximum == rhs.maximum && lhs.isInteger == rhs.isInteger
            && lhs.options.map(\.label) == rhs.options.map(\.label) && lhs.options.map(\.value) == rhs.options.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(kind)
    }

    /// The declarations of `source`, in order. A call whose options aren't literals is skipped.
    public static func declarations(in source: String) -> [SceneScriptPropertyDeclaration] {
        guard let regex = try? NSRegularExpression(pattern: #"\.add(Slider|Checkbox|Text|Combo|Color)\s*\(\s*\{"#) else { return [] }
        let text = source as NSString
        var found: [SceneScriptPropertyDeclaration] = []
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let kindName = text.substring(with: match.range(at: 1)).lowercased()
            guard let kind = Kind(rawValue: kindName) else { continue }
            let open = NSMaxRange(match.range) - 1
            guard let literal = balancedObject(in: text, from: open),
                  case .object(let fields)? = JavaScriptLiteral.value(of: literal),
                  let name = fields["name"]?.stringValue, !name.isEmpty else { continue }
            var options: [(label: String, value: SceneJSONValue)] = []
            if case .array(let entries)? = fields["options"] {
                for entry in entries {
                    guard let value = entry["value"] else { continue }
                    options.append((entry["label"]?.stringValue ?? SceneScriptValueText.text(value), value))
                }
            }
            let value = kind == .combo ? options.first?.value : fields["value"]
            found.append(SceneScriptPropertyDeclaration(
                name: name, label: fields["label"]?.stringValue ?? name, kind: kind, value: value,
                minimum: fields["min"]?.doubleValue, maximum: fields["max"]?.doubleValue,
                isInteger: fields["integer"]?.boolValue == true, options: options))
        }
        return found
    }

    /// The `{…}` starting at `open`, braces balanced outside strings and comments.
    static func balancedObject(in text: NSString, from open: Int) -> String? {
        let rest = text.substring(from: open)
        var depth = 0
        for token in JavaScriptTokenizer.tokens(in: rest) where token.kind == .punctuation {
            let character = (rest as NSString).substring(with: token.range)
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return (rest as NSString).substring(to: NSMaxRange(token.range)) }
            }
        }
        return nil
    }
}

enum SceneScriptValueText {
    static func text(_ value: SceneJSONValue) -> String {
        UserPropertyDraft.text(of: value)
    }
}

/// A JavaScript object or array literal of literals (strings, numbers, flags, `null`, nested
/// literals; keys bare or quoted; trailing commas) read as JSON; nil for anything else.
enum JavaScriptLiteral {
    static func value(of source: String) -> SceneJSONValue? {
        // A colour's `new Vec3(1, 0, 0)` (WE's Insert Property › Color) reads as WE stores it, "1 0 0".
        let literal = vectorsAsText(source)
        let text = literal as NSString
        var json = ""
        var expectsKey = false
        var stack: [Character] = []
        let tokens = JavaScriptTokenizer.tokens(in: literal).filter {
            $0.kind != .lineComment && $0.kind != .blockComment
        }
        for (position, token) in tokens.enumerated() {
            let word = text.substring(with: token.range)
            switch token.kind {
            case .punctuation:
                switch word {
                case "{": stack.append("{"); expectsKey = true; json += "{"
                case "[": stack.append("["); expectsKey = false; json += "["
                case "}", "]":
                    guard let open = stack.popLast(), (open == "{") == (word == "}") else { return nil }
                    if json.hasSuffix(",") { json.removeLast() }
                    json += word
                    expectsKey = false
                case ",": json += ","; expectsKey = stack.last == "{"
                case ":": json += ":"; expectsKey = false
                case "-":
                    // A negative number: the sign of the next token.
                    guard tokens.indices.contains(position + 1), tokens[position + 1].kind == .number else { return nil }
                    json += "-"
                default: return nil
                }
            case .string:
                guard let string = unquoted(word) else { return nil }
                json += encoded(string)
            case .number:
                guard let number = Double(word), number.isFinite else { return nil }
                json += expectsKey ? encoded(word) : word.hasPrefix(".") ? "0" + word : word
            case .identifier, .keyword, .api:
                if expectsKey {
                    json += encoded(word)
                } else if ["true", "false", "null"].contains(word) {
                    json += word
                } else {
                    return nil
                }
            default:
                return nil
            }
        }
        guard stack.isEmpty, let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SceneJSONValue.self, from: data) else { return nil }
        return decoded
    }

    /// `new Vec2/3/4(…)` of number literals replaced by the string of its components.
    static func vectorsAsText(_ source: String) -> String {
        guard source.contains("new"),
              let regex = try? NSRegularExpression(pattern: #"\bnew\s+Vec[234]\s*\(\s*(-?[0-9.]+(?:[eE][-+]?[0-9]+)?(?:\s*,\s*-?[0-9.]+(?:[eE][-+]?[0-9]+)?)*)\s*\)"#)
        else { return source }
        let text = source as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            result += text.substring(with: NSRange(location: location, length: match.range.location - location))
            let components = text.substring(with: match.range(at: 1)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            result += "'" + components.joined(separator: " ") + "'"
            location = NSMaxRange(match.range)
        }
        return result + text.substring(from: location)
    }

    /// A string literal's text, escapes resolved; nil when unterminated.
    static func unquoted(_ literal: String) -> String? {
        guard let quote = literal.first, literal.count >= 2, literal.last == quote else { return nil }
        var result = ""
        var escaping = false
        for character in literal.dropFirst().dropLast() {
            if escaping {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    static func encoded(_ string: String) -> String {
        let data = (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
