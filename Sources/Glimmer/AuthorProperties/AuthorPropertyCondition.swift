import Foundation

enum AuthorPropertyConditionResult: Equatable, Sendable {
    case visible, hidden, unsupported(String)
}

/// A closed expression grammar, never JavaScript execution. Calls, assignments,
/// indexing, member chains and arithmetic are explicitly unsupported.
enum AuthorPropertyCondition {
    static func evaluate(_ expression: String?, values: [String: GWJSONValue]) -> AuthorPropertyConditionResult {
        guard let expression, !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .visible }
        do {
            guard expression.utf8.count <= 4096 else { throw AuthorPropertyError(message: "条件表达式超过长度限制") }
            var parser = try Parser(expression)
            let node = try parser.parse()
            let value = try evaluate(node, values: values)
            return try truth(value) ? .visible : .hidden
        } catch { return .unsupported(error.localizedDescription) }
    }

    private enum Token: Equatable {
        case value(GWJSONValue), name(String), op(String), end
    }
    private indirect enum Node {
        case value(GWJSONValue), reference(String), not(Node), binary(String, Node, Node)
    }

    private struct Parser {
        var tokens: [Token] = []
        var index = 0
        var depth = 0
        init(_ text: String) throws {
            let input = Array(text)
            var cursor = 0
            func failure() -> AuthorPropertyError { .init(message: "条件含有尚不支持的语法；未执行任何代码") }
            while cursor < input.count {
                let c = input[cursor]
                if c.isWhitespace { cursor += 1; continue }
                if c == "\"" || c == "'" {
                    let quote = c
                    cursor += 1
                    var output = ""
                    var closed = false
                    while cursor < input.count {
                        let character = input[cursor]; cursor += 1
                        if character == "\n" || character == "\r" { throw failure() }
                        if character == quote { closed = true; break }
                        if character == "\\" {
                            guard cursor < input.count else { throw failure() }
                            let escaped = input[cursor]; cursor += 1
                            switch escaped {
                            case "n": output.append("\n")
                            case "r": output.append("\r")
                            case "t": output.append("\t")
                            case "\\", "\"", "'": output.append(escaped)
                            default: throw failure()
                            }
                        } else { output.append(character) }
                    }
                    guard closed else { throw failure() }
                    tokens.append(.value(.string(output)))
                } else if c.isASCII && (c.isLetter || c == "_") {
                    let start = cursor
                    while cursor < input.count && input[cursor].isASCII && (input[cursor].isLetter || input[cursor].isNumber || input[cursor] == "_") { cursor += 1 }
                    let name = String(input[start..<cursor])
                    switch name {
                    case "true": tokens.append(.value(.bool(true)))
                    case "false": tokens.append(.value(.bool(false)))
                    case "null": tokens.append(.value(.null))
                    default: tokens.append(.name(name))
                    }
                } else if c.isASCII && (c.isNumber || (c == "-" && cursor + 1 < input.count && input[cursor + 1].isNumber)
                           || (c == "." && cursor + 1 < input.count && input[cursor + 1].isNumber)) {
                    let start = cursor
                    while cursor < input.count && "0123456789.eE+-".contains(input[cursor]) { cursor += 1 }
                    guard let number = Double(String(input[start..<cursor])), number.isFinite else { throw failure() }
                    tokens.append(.value(.number(number)))
                } else {
                    let operators = ["===", "!==", "==", "!=", ">=", "<=", "&&", "||", "!", ">", "<", "(", ")", "."]
                    guard let op = operators.first(where: { Array($0).elementsEqual(input.dropFirst(cursor).prefix($0.count)) }) else { throw failure() }
                    cursor += op.count
                    tokens.append(.op(op))
                }
                guard tokens.count <= 512 else { throw AuthorPropertyError(message: "条件表达式超过复杂度限制") }
            }
            tokens.append(.end)
        }
        var token: Token { tokens[index] }
        mutating func accept(_ op: String) -> Bool {
            if token == .op(op) { index += 1; return true }; return false
        }
        mutating func parse() throws -> Node {
            let value = try logicalOr()
            guard token == .end else { throw AuthorPropertyError(message: "条件包含未支持的调用、操作或成员访问") }
            return value
        }
        mutating func logicalOr() throws -> Node {
            var left = try logicalAnd()
            while accept("||") { left = .binary("||", left, try logicalAnd()) }
            return left
        }
        mutating func logicalAnd() throws -> Node {
            var left = try comparison()
            while accept("&&") { left = .binary("&&", left, try comparison()) }
            return left
        }
        mutating func comparison() throws -> Node {
            var left = try relational()
            while case .op(let op) = token, ["==", "!=", "===", "!=="].contains(op) {
                index += 1; left = .binary(op, left, try relational())
            }
            return left
        }
        mutating func relational() throws -> Node {
            var left = try unary()
            while case .op(let op) = token, [">", ">=", "<", "<="].contains(op) {
                index += 1; left = .binary(op, left, try unary())
            }
            return left
        }
        mutating func unary() throws -> Node {
            depth += 1; defer { depth -= 1 }
            guard depth <= 32 else { throw AuthorPropertyError(message: "条件嵌套超过限制") }
            if accept("!") { return .not(try unary()) }
            if accept("(") {
                let node = try logicalOr()
                guard accept(")") else { throw AuthorPropertyError(message: "条件缺少右括号") }
                return node
            }
            if case .value(let value) = token { index += 1; return .value(value) }
            if case .name(let key) = token {
                index += 1
                guard accept("."), token == .name("value") else { throw AuthorPropertyError(message: "条件只支持 属性名.value 引用") }
                index += 1
                return .reference(key)
            }
            throw AuthorPropertyError(message: "条件缺少有效值")
        }
    }

    private static func truth(_ value: GWJSONValue) throws -> Bool {
        switch value {
        case .bool(let value): return value
        case .number(let value):
            guard value.isFinite else { throw AuthorPropertyError(message: "条件引用了非有限数值") }
            return value != 0
        case .string(let value): return !value.isEmpty
        case .null: return false
        case .array, .object: return true
        }
    }
    private static func evaluate(_ node: Node, values: [String: GWJSONValue]) throws -> GWJSONValue {
        switch node {
        case .value(let value): return value
        case .reference(let key):
            guard let value = values[key] else { throw AuthorPropertyError(message: "条件引用了缺失的属性 \(key)") }
            if let number = value.numberValue, !number.isFinite { throw AuthorPropertyError(message: "条件引用了非有限数值") }
            return value
        case .not(let node): return .bool(try !truth(evaluate(node, values: values)))
        case .binary(let op, let lhs, let rhs):
            let left = try evaluate(lhs, values: values)
            if op == "&&" { return try truth(left) ? evaluate(rhs, values: values) : left }
            if op == "||" { return try truth(left) ? left : evaluate(rhs, values: values) }
            let right = try evaluate(rhs, values: values)
            if ["==", "!=", "===", "!=="].contains(op) {
                let sameType: Bool
                switch (left, right) {
                case (.bool, .bool), (.number, .number), (.string, .string), (.null, .null): sameType = true
                case (.array, _), (.object, _), (_, .array), (_, .object):
                    throw AuthorPropertyError(message: "条件不支持对象或数组的相等比较")
                default: sameType = false
                }
                if !sameType && ["==", "!="].contains(op) { throw AuthorPropertyError(message: "条件中的 JavaScript 隐式类型转换尚未支持") }
                let equal: Bool
                if case .string(let a) = left, case .string(let b) = right {
                    equal = Array(a.utf16) == Array(b.utf16)
                } else { equal = sameType && left == right }
                return .bool(["!=", "!=="].contains(op) ? !equal : equal)
            }
            let less: Bool
            let equal: Bool
            switch (left, right) {
            case (.number(let a), .number(let b)) where a.isFinite && b.isFinite: less = a < b; equal = a == b
            case (.string(let a), .string(let b)): less = Array(a.utf16).lexicographicallyPrecedes(Array(b.utf16)); equal = Array(a.utf16) == Array(b.utf16)
            default: throw AuthorPropertyError(message: "大小比较只支持同类型数字或文本")
            }
            return .bool(op == "<" ? less : op == "<=" ? less || equal : op == ">" ? !less && !equal : !less)
        }
    }
}
