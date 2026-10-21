import Foundation
import JavaScriptCore

/// A property's `condition` (`clock.value == 1`, `style.value == "cycle" && mode.value != "dual"`):
/// the one evaluator the app's property sidebar and the editor's live preview share, so they can't
/// disagree, and read as a rule the condition builder can show when it is one comparison. WE
/// evaluates conditions as JavaScript over the other properties; this reads the subset authors use:
/// `name.value`, string, number and flag literals, `== != === !== < <= > >=`, `! && ||` and
/// parentheses, with JavaScript's precedence. Values are the sidebar's strings; a comparison is
/// numeric when both sides are numbers (flags count as 1 and 0, as JavaScript's loose `==` compares
/// them), else textual. Anything else runs as JavaScript, as in WE (`UserPropertyConditionScope`);
/// an empty condition, or a script that loops or throws, holds.
public struct UserPropertyConditionExpression: Sendable {
    private indirect enum Node: Sendable {
        case literal(String)
        case property(String)
        case not(Node)
        case and(Node, Node)
        case or(Node, Node)
        case compare(String, Node, Node)
    }

    public let source: String
    private let root: Node?

    public init(_ source: String) {
        self.source = source
        var parser = Parser(tokens: Self.tokenize(source.trimmingCharacters(in: .whitespacesAndNewlines)))
        if let node = parser.parseOr(), parser.atEnd { root = node } else { root = nil }
    }

    /// The expression is in the subset this reads (an empty one is not).
    public var isUnderstood: Bool { root != nil }

    /// Whether the property shows for `values` (property key to sidebar value).
    public func evaluate(_ values: [String: String]) -> Bool {
        guard let root else { return isScript ? UserPropertyConditionScope(values: values).evaluate(self) : true }
        return Self.truthy(Self.eval(root, values))
    }

    /// Whether the expression is a script outside the subset, run as JavaScript.
    var isScript: Bool { root == nil && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The properties the expression reads.
    public var referencedKeys: Set<String> {
        guard let root else { return [] }
        var keys = Set<String>()
        func walk(_ node: Node) {
            switch node {
            case .literal: break
            case .property(let name): keys.insert(name)
            case .not(let inner): walk(inner)
            case .and(let lhs, let rhs), .or(let lhs, let rhs), .compare(_, let lhs, let rhs): walk(lhs); walk(rhs)
            }
        }
        walk(root)
        return keys
    }

    // MARK: Evaluation

    private static func eval(_ node: Node, _ values: [String: String]) -> String {
        switch node {
        case .literal(let value): return value
        case .property(let name): return values[name] ?? ""
        case .not(let inner): return truthy(eval(inner, values)) ? "false" : "true"
        case .and(let lhs, let rhs): return truthy(eval(lhs, values)) && truthy(eval(rhs, values)) ? "true" : "false"
        case .or(let lhs, let rhs): return truthy(eval(lhs, values)) || truthy(eval(rhs, values)) ? "true" : "false"
        case .compare(let op, let lhs, let rhs): return compare(op, eval(lhs, values), eval(rhs, values)) ? "true" : "false"
        }
    }

    static func number(_ value: String) -> Double? {
        switch value.lowercased() {
        case "true": return 1
        case "false": return 0
        default: return Double(value.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func compare(_ op: String, _ lhs: String, _ rhs: String) -> Bool {
        if let l = number(lhs), let r = number(rhs) {
            switch op {
            case "==", "===": return l == r
            case "!=", "!==": return l != r
            case "<": return l < r
            case "<=": return l <= r
            case ">": return l > r
            case ">=": return l >= r
            default: return false
            }
        }
        switch op {
        case "==", "===": return lhs == rhs
        case "!=", "!==": return lhs != rhs
        case "<": return lhs < rhs
        case "<=": return lhs <= rhs
        case ">": return lhs > rhs
        case ">=": return lhs >= rhs
        default: return false
        }
    }

    private static func truthy(_ value: String) -> Bool {
        if let number = number(value) { return number != 0 }
        return !value.isEmpty
    }

    // MARK: Parsing

    private enum Token: Equatable {
        case identifier(String)
        case string(String)
        case number(String)
        case op(String)
    }

    static let operators = ["===", "!==", "==", "!=", "<=", ">=", "&&", "||", "<", ">", "!", "(", ")"]

    private static func tokenize(_ source: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(source)
        var index = 0
        while index < chars.count {
            let c = chars[index]
            if c.isWhitespace { index += 1; continue }
            if c == "\"" || c == "'" {
                var end = index + 1
                var text = ""
                while end < chars.count, chars[end] != c {
                    if chars[end] == "\\", end + 1 < chars.count { end += 1 }
                    text.append(chars[end])
                    end += 1
                }
                tokens.append(.string(text))
                index = end + 1
                continue
            }
            if c.isNumber || (c == "-" && index + 1 < chars.count && chars[index + 1].isNumber) {
                var end = index + 1
                while end < chars.count, chars[end].isNumber || chars[end] == "." { end += 1 }
                tokens.append(.number(String(chars[index..<end])))
                index = end
                continue
            }
            if c.isLetter || c == "_" || c == "$" {
                var end = index + 1
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || "_.$".contains(chars[end]) { end += 1 }
                tokens.append(.identifier(String(chars[index..<end])))
                index = end
                continue
            }
            if let op = operators.first(where: { op in
                index + op.count <= chars.count && String(chars[index..<(index + op.count)]) == op
            }) {
                tokens.append(.op(op))
                index += op.count
                continue
            }
            tokens.append(.op(String(c))) // Unknown: parsing fails, the condition holds.
            index += 1
        }
        return tokens
    }

    private struct Parser {
        let tokens: [Token]
        var position = 0

        var atEnd: Bool { position == tokens.count }

        private func peek() -> Token? { position < tokens.count ? tokens[position] : nil }

        private mutating func accept(_ op: String) -> Bool {
            if peek() == .op(op) { position += 1; return true }
            return false
        }

        mutating func parseOr() -> Node? {
            guard var lhs = parseAnd() else { return nil }
            while accept("||") {
                guard let rhs = parseAnd() else { return nil }
                lhs = .or(lhs, rhs)
            }
            return lhs
        }

        mutating func parseAnd() -> Node? {
            guard var lhs = parseComparison() else { return nil }
            while accept("&&") {
                guard let rhs = parseComparison() else { return nil }
                lhs = .and(lhs, rhs)
            }
            return lhs
        }

        mutating func parseComparison() -> Node? {
            guard let lhs = parseUnary() else { return nil }
            for op in ["===", "!==", "==", "!=", "<=", ">=", "<", ">"] where accept(op) {
                guard let rhs = parseUnary() else { return nil }
                return .compare(op, lhs, rhs)
            }
            return lhs
        }

        /// `!` binds tighter than a comparison, as in JavaScript: `!a.value == 1` is
        /// `(!a.value) == 1`, and `a.value == !b.value` negates the right-hand side.
        mutating func parseUnary() -> Node? {
            if accept("!") { return parseUnary().map { .not($0) } }
            return parsePrimary()
        }

        mutating func parsePrimary() -> Node? {
            guard let token = peek() else { return nil }
            position += 1
            switch token {
            case .string(let text), .number(let text): return .literal(text)
            case .identifier(let name):
                if name == "true" || name == "false" { return .literal(name) }
                return .property(name.hasSuffix(".value") ? String(name.dropLast(".value".count)) : name)
            case .op("("):
                guard let inner = parseOr(), accept(")") else { return nil }
                return inner
            default:
                return nil
            }
        }
    }
}

/// The properties a sidebar's conditions run against, as WE's JavaScript sees them: each one an
/// object with its `value` and `text` (label). Some authors write to `text` from a condition
/// (`x.value ? x.text = x.text.replace('Disabled','Enabled') : …`) so a checkbox's label follows
/// it; `texts` holds the labels after each evaluation. Conditions run in the order given, sharing
/// the labels, as WE runs them down the sidebar.
public final class UserPropertyConditionScope {
    private let values: [String: String]
    public private(set) var texts: [String: String]
    private var context: JSContext?

    public init(values: [String: String], texts: [String: String] = [:]) {
        self.values = values
        self.texts = texts
    }

    /// Whether the property with `expression` as its condition shows.
    public func evaluate(_ expression: UserPropertyConditionExpression) -> Bool {
        guard expression.isScript else { return expression.evaluate(values) }
        // A condition is an expression; one that could loop would hang the sidebar, so it holds.
        guard expression.source.range(of: #"\b(while|for|do|function)\b|=>"#, options: .regularExpression) == nil,
              let context = scriptContext() else { return true }
        let result = context.evaluateScript(expression.source)
        guard let result, context.exception == nil else {
            context.exception = nil
            return true
        }
        for key in texts.keys {
            if let text = context.objectForKeyedSubscript(key)?.objectForKeyedSubscript("text"), text.isString {
                texts[key] = text.toString()
            }
        }
        return result.toBool()
    }

    private func scriptContext() -> JSContext? {
        if let context { return context }
        guard let context = JSContext() else { return nil }
        for key in Set(values.keys).union(texts.keys) {
            let property = JSValue(newObjectIn: context)
            property?.setObject(Self.scriptValue(values[key] ?? ""), forKeyedSubscript: "value")
            property?.setObject(texts[key] ?? "", forKeyedSubscript: "text")
            context.setObject(property, forKeyedSubscript: key as NSString)
        }
        self.context = context
        return context
    }

    /// A sidebar value as WE hands it to the script: flags and numbers typed, the rest text.
    private static func scriptValue(_ value: String) -> Any {
        switch value.lowercased() {
        case "true": return true
        case "false": return false
        default: return Double(value.trimmingCharacters(in: .whitespaces)) ?? value
        }
    }
}

/// A condition the builder shows as "Show when <property> <is/is not> <value>": one comparison of
/// a property with a literal, which is what WE's editor writes and most conditions are.
public struct UserPropertyConditionRule: Hashable, Sendable {
    public enum Comparison: String, CaseIterable, Sendable {
        case equal = "=="
        case notEqual = "!="
        case less = "<"
        case lessOrEqual = "<="
        case greater = ">"
        case greaterOrEqual = ">="
    }

    public var key: String
    public var comparison: Comparison
    public var value: String

    public init(key: String, comparison: Comparison = .equal, value: String) {
        self.key = key
        self.comparison = comparison
        self.value = value
    }

    /// The rule a condition is, when it is exactly one `key.value <op> literal`.
    public init?(_ condition: String) {
        let pattern = #"^\s*([A-Za-z_$][A-Za-z0-9_$]*)\.value\s*(===|!==|==|!=|<=|>=|<|>)\s*(.+?)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: condition, range: NSRange(condition.startIndex..., in: condition)),
              let keyRange = Range(match.range(at: 1), in: condition),
              let opRange = Range(match.range(at: 2), in: condition),
              let valueRange = Range(match.range(at: 3), in: condition) else { return nil }
        var op = String(condition[opRange])
        if op == "===" { op = "==" } else if op == "!==" { op = "!=" }
        guard let comparison = Comparison(rawValue: op) else { return nil }
        let literal = String(condition[valueRange])
        let value: String
        if let quote = literal.first, quote == "\"" || quote == "'" {
            guard literal.count >= 2, literal.last == quote else { return nil }
            let inner = literal.dropFirst().dropLast()
            guard !inner.contains(quote) else { return nil }
            value = String(inner)
        } else {
            guard literal == "true" || literal == "false" || Double(literal) != nil else { return nil }
            value = literal
        }
        self.init(key: String(condition[keyRange]), comparison: comparison, value: value)
    }

    /// The condition as project.json writes it: numbers and flags bare, text quoted.
    public var condition: String {
        let bare = value == "true" || value == "false" || Double(value) != nil
        let literal = bare ? value : "\"" + value.replacingOccurrences(of: "\"", with: "'") + "\""
        return "\(key).value \(comparison.rawValue) \(literal)"
    }
}
