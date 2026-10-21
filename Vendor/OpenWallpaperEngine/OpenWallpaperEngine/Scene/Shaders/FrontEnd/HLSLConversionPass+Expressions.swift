import Foundation

extension HLSLConversionPass {
    // MARK: - Conversions

    /// Makes HLSL's implicit conversion of `expression` to `type` explicit. `onlyScalars` limits it
    /// to scalar sources (a condition: HLSL has no test of a whole vector).
    mutating func convert(_ expression: Expression, to type: HLSLType, onlyScalars: Bool = false) {
        guard let from = expression.type else { return }
        if onlyScalars, case .scalar = from {} else if onlyScalars { return }
        guard let constructor = HLSLConversion.constructor(from: from, to: type) else { return }
        edits.wrap(expression.start, expression.end, constructor + "(", ")")
    }

    func span(_ first: Expression, _ last: Expression, type: HLSLType?) -> Expression {
        Expression(type: type, start: first.start, end: last.end, firstToken: first.firstToken, endToken: last.endToken)
    }

    // MARK: - Operators

    /// `a, b` (only where a list of expressions is allowed: statements and `for` headers).
    mutating func expression() throws -> Expression {
        var result = try assignment()
        while isPunctuation(",") {
            position += 1
            let next = try assignment()
            result = span(result, next, type: next.type)
        }
        return result
    }

    static let assignmentOperators: Set<String> = ["=", "+=", "-=", "*=", "/=", "%=", "<<=", ">>=", "&=", "|=", "^="]

    mutating func assignment() throws -> Expression {
        let target = try conditional()
        guard let token = current, token.kind == .punctuation, Self.assignmentOperators.contains(token.text) else { return target }
        let operatorIndex = position
        position += 1
        let value = try assignment()
        guard let targetType = target.type else { return span(target, value, type: nil) }
        if token.text == "=" {
            convert(value, to: targetType)
        } else if ["+=", "-=", "*=", "/="].contains(token.text), let valueType = value.type {
            compoundAssignment(target, targetType, operatorIndex, value, valueType)
        } else if token.text == "%=", let valueType = value.type, valueType.scalarKind == .float || targetType.scalarKind == .float {
            // `x %= y` → `x = weMod(x, y)`, HLSL's `%` on floats.
            guard target.isSimpleLValue else { return span(target, value, type: targetType) }
            let name = edits.render(code, target.start, target.end, consume: false)
            edits.replace(tokens[operatorIndex].start, tokens[operatorIndex].end, "= weMod(\(name),")
            edits.suffix(value.end, ")")
        }
        return span(target, value, type: targetType)
    }

    /// `x op= e`: the value converts as an operand of `op`; a result of another type (an int
    /// multiplied by a float) converts back, as HLSL does: `x = T(x op (e))`.
    mutating func compoundAssignment(_ target: Expression, _ targetType: HLSLType, _ operatorIndex: Int,
                                     _ value: Expression, _ valueType: HLSLType) {
        if case .matrix = targetType { return }
        guard targetType.isScalarOrVector, valueType.isScalarOrVector,
              let result = HLSLConversion.componentwise(targetType, valueType) else { return }
        let operation = String(tokens[operatorIndex].text.dropLast())
        if result.withKind(.float) == targetType.withKind(.float) || result.components == 1 && targetType.components != 1 {
            // Same shape: only the value may need converting (truncated, splat or of another kind).
            let operand = valueType.components == 1 ? HLSLType.scalar(targetType.scalarKind!) : targetType
            if valueType.scalarKind == .bool || valueType.components != 1 { convert(value, to: operand) }
            if result.scalarKind == targetType.scalarKind || result.scalarKind == .bool { return }
        } else if valueType.components ?? 0 > targetType.components ?? 0 {
            convert(value, to: targetType.withKind(valueType.scalarKind!))
        }
        let kindChanges = !HLSLConversion.isImplicitInGLSL(HLSLConversion.promoted(targetType.scalarKind!, valueType.scalarKind!),
                                                           targetType.scalarKind!)
        guard kindChanges, target.isSimpleLValue, let constructor = targetType.glslName else { return }
        let name = edits.render(code, target.start, target.end, consume: false)
        if valueType.scalarKind == .bool { convert(value, to: valueType.withKind(.int)) }
        edits.replace(tokens[operatorIndex].start, tokens[operatorIndex].end, "= \(constructor)(\(name) \(operation) (")
        edits.suffix(value.end, "))")
    }

    mutating func conditional() throws -> Expression {
        let test = try binary(0)
        guard isPunctuation("?") else { return test }
        position += 1
        let yes = try assignment()
        try expect(":")
        let no = try conditional()
        convert(test, to: .scalar(.bool), onlyScalars: true)
        var type: HLSLType?
        if let a = yes.type, let b = no.type {
            if a == b {
                type = a
            } else if let common = HLSLConversion.componentwise(a, b) {
                let size = max(a.components!, b.components!) == 1 ? 1 : common.components!
                let result = HLSLType.numeric(common.scalarKind!, a.components == 1 || b.components == 1 ? max(a.components!, b.components!) : size)
                convert(yes, to: result)
                convert(no, to: result)
                type = result
            }
        }
        return span(test, no, type: type)
    }

    static let binaryLevels: [Set<String>] = [
        ["||"], ["^^"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", ">", "<=", ">="], ["<<", ">>"],
        ["+", "-"], ["*", "/", "%"],
    ]

    mutating func binary(_ level: Int) throws -> Expression {
        guard level < Self.binaryLevels.count else { return try unary() }
        var left = try binary(level + 1)
        while let token = current, token.kind == .punctuation, Self.binaryLevels[level].contains(token.text) {
            let operatorIndex = position
            position += 1
            let right = try binary(level + 1)
            left = combine(left, operatorIndex, right, level: level)
        }
        return left
    }

    /// The typed `left op right`, with HLSL's operand conversions.
    mutating func combine(_ left: Expression, _ operatorIndex: Int, _ right: Expression, level: Int) -> Expression {
        let op = tokens[operatorIndex].text
        guard let a = left.type, let b = right.type else {
            return span(left, right, type: level <= 2 || level == 6 || level == 7 ? .scalar(.bool) : nil)
        }
        switch level {
        case 0, 1, 2: // logical: HLSL tests numbers against zero
            convert(left, to: .scalar(.bool), onlyScalars: true)
            convert(right, to: .scalar(.bool), onlyScalars: true)
            return span(left, right, type: .scalar(.bool))
        case 6: // equality
            if a.components == 1, b.components == 1, let common = HLSLConversion.componentwise(a, b) {
                if a.scalarKind == .bool || b.scalarKind == .bool, a != b {
                    convert(left, to: common)
                    convert(right, to: common)
                }
            }
            return span(left, right, type: .scalar(.bool))
        case 7: // relational: component-wise on vectors in HLSL
            guard let common = HLSLConversion.componentwise(a, b) else { return span(left, right, type: .scalar(.bool)) }
            if common.components == 1 {
                if a.scalarKind == .bool { convert(left, to: common) }
                if b.scalarKind == .bool { convert(right, to: common) }
                return span(left, right, type: .scalar(.bool))
            }
            let function = ["<": "lessThan", ">": "greaterThan", "<=": "lessThanEqual", ">=": "greaterThanEqual"][op]!
            let operand = common.scalarKind == .bool ? common.withKind(.int) : common
            convert(left, to: operand)
            convert(right, to: operand)
            edits.prefix(left.start, function + "(")
            edits.replace(tokens[operatorIndex].start, tokens[operatorIndex].end, ",")
            edits.suffix(right.end, ")")
            return span(left, right, type: .vector(.bool, common.components!))
        case 3, 4, 5, 8: // bitwise and shifts: integers only
            return span(left, right, type: a)
        default:
            return arithmetic(left, a, operatorIndex, right, b)
        }
    }

    /// `+ - * / %`: vectors of different sizes truncate to the narrower, bools take part as 0 or 1,
    /// a matrix product truncates its vector, and `%` on floats is HLSL's `fmod` (`weMod`).
    mutating func arithmetic(_ left: Expression, _ a: HLSLType, _ operatorIndex: Int,
                             _ right: Expression, _ b: HLSLType) -> Expression {
        let op = tokens[operatorIndex].text
        switch (a, b) {
        case (.matrix(let c, let r), .vector(_, let n)) where op == "*":
            if n > c { convert(right, to: .vector(.float, c)) }
            return span(left, right, type: n >= c ? .vector(.float, r) : nil)
        case (.vector(_, let n), .matrix(let c, let r)) where op == "*":
            if n > r { convert(left, to: .vector(.float, r)) }
            return span(left, right, type: n >= r ? .vector(.float, c) : nil)
        case (.matrix(let c, let r), .matrix(let c2, let r2)) where op == "*":
            return span(left, right, type: c == r2 ? .matrix(columns: c2, rows: r) : nil)
        case (.matrix, .matrix), (.matrix, .scalar), (.scalar, .matrix):
            return span(left, right, type: a.components == 1 ? b : a)
        default:
            break
        }
        guard let common = HLSLConversion.componentwise(a, b) else { return span(left, right, type: nil) }
        var kind = common.scalarKind!
        if kind == .bool { kind = .int }
        let result = common.withKind(kind)
        for (operand, type) in [(left, a), (right, b)] {
            let target = type.components == 1 ? HLSLType.scalar(kind) : result
            // Scalars of a GLSL-convertible kind and same-size vectors of one stay as written.
            if type.components == 1, HLSLConversion.isImplicitInGLSL(type.scalarKind!, kind) { continue }
            convert(operand, to: target)
        }
        if op == "%", kind == .float {
            edits.prefix(left.start, "weMod(")
            edits.replace(tokens[operatorIndex].start, tokens[operatorIndex].end, ",")
            edits.suffix(right.end, ")")
        }
        return span(left, right, type: result)
    }

    mutating func unary() throws -> Expression {
        guard let token = current, token.kind == .punctuation else { return try postfix() }
        switch token.text {
        case "-", "+", "~", "++", "--":
            let first = position
            position += 1
            let operand = try unary()
            return Expression(type: operand.type, start: token.start, end: operand.end, firstToken: first, endToken: operand.endToken)
        case "!":
            let first = position
            position += 1
            let operand = try unary()
            convert(operand, to: .scalar(.bool), onlyScalars: true)
            return Expression(type: .scalar(.bool), start: token.start, end: operand.end, firstToken: first, endToken: operand.endToken)
        default:
            return try postfix()
        }
    }

    // MARK: - Postfix and primary

    static let swizzleSets: [Set<Character>] = [Set("xyzw"), Set("rgba"), Set("stpq")]

    mutating func postfix() throws -> Expression {
        var result = try primary()
        while let token = current, token.kind == .punctuation {
            switch token.text {
            case "[":
                position += 1
                let index = try expression()
                try expect("]")
                let close = tokens[position - 1]
                if index.type?.scalarKind == .float || index.type?.scalarKind == .bool, index.type?.components == 1 {
                    convert(index, to: .scalar(.int))
                }
                var element: HLSLType?
                var packed = false
                switch result.type {
                case .array(let type, let size):
                    element = type
                    packed = type == .scalar(.float) && size.map { $0 % 4 == 0 } == true
                case .vector(let kind, _): element = .scalar(kind)
                case .matrix(_, let rows): element = .vector(.float, rows)
                case .scalar(.float) where result.packedArrayElement:
                    // `x[i][j]` on a packed `float x[4n]` → `x[i * 4 + j]`.
                    packedIndex(result, index)
                    element = .scalar(.float)
                default: element = nil
                }
                var next = Expression(type: element, start: result.start, end: close.end, firstToken: result.firstToken,
                                      endToken: position)
                next.packedArrayElement = packed
                next.isSimpleLValue = result.isSimpleLValue && index.isSimpleLValue || result.isSimpleLValue && index.endToken - index.firstToken == 1
                result = next
            case ".":
                guard position + 1 < tokens.count, tokens[position + 1].kind == .identifier else { throw Failure() }
                let field = tokens[position + 1]
                position += 2
                if isPunctuation("(") {
                    // A method (`OUT.Append(v)`, `a.length()`): its arguments are typed, the result isn't.
                    let arguments = try callArguments()
                    let close = tokens[position - 1]
                    let type: HLSLType? = field.text == "length" && arguments.isEmpty ? .scalar(.int) : nil
                    result = Expression(type: type, start: result.start, end: close.end, firstToken: result.firstToken,
                                        endToken: position)
                    continue
                }
                result = member(result, field)
            case "++", "--":
                position += 1
                result = Expression(type: result.type, start: result.start, end: token.end, firstToken: result.firstToken,
                                    endToken: position)
            default:
                return result
            }
        }
        return result
    }

    /// `base.field`: a struct member or a swizzle (HLSL swizzles scalars too: `f.xxx` → `vec3(f)`).
    mutating func member(_ base: Expression, _ field: GLSLToken) -> Expression {
        var type: HLSLType?
        switch base.type {
        case .structure(let name):
            type = structs[name]?[field.text]
        case .scalar(let kind), .vector(let kind, _):
            let characters = Array(field.text)
            guard characters.count <= 4, Self.swizzleSets.contains(where: { set in characters.allSatisfy(set.contains) }) else { break }
            type = .numeric(kind, characters.count)
            if base.type?.components == 1, characters.allSatisfy({ $0 == "x" || $0 == "r" }) {
                let dot = tokens[position - 2]
                if characters.count == 1 {
                    edits.replace(dot.start, field.end, "")
                } else if let name = type?.glslName {
                    edits.prefix(base.start, name + "(")
                    edits.replace(dot.start, field.end, ")")
                }
            }
        default:
            break
        }
        var result = Expression(type: type, start: base.start, end: field.end, firstToken: base.firstToken, endToken: position)
        result.isSimpleLValue = base.isSimpleLValue
        return result
    }

    /// `x[i][j]` → `x[int(i) * 4 + int(j)]` (`element` is `x[i]`, `index` is `j`).
    mutating func packedIndex(_ element: Expression, _ index: Expression) {
        let firstClose = element.endToken - 1
        guard let firstOpen = (element.firstToken..<firstClose).last(where: { tokens[$0].text == "[" && closing(from: $0) == firstClose }),
              firstOpen + 1 < firstClose else { return }
        edits.prefix(tokens[firstOpen + 1].start, "int(")
        edits.replace(tokens[firstClose].start, index.start, ") * 4 + int(")
        edits.suffix(index.end, ")")
    }

    mutating func callArguments() throws -> [Expression] {
        try expect("(")
        var arguments: [Expression] = []
        if isPunctuation(")") { position += 1; return arguments }
        while true {
            arguments.append(try assignment())
            if isPunctuation(",") { position += 1; continue }
            try expect(")")
            return arguments
        }
    }

    mutating func primary() throws -> Expression {
        guard let token = current else { throw Failure() }
        let first = position
        switch token.kind {
        case .number(let kind):
            position += 1
            return Expression(type: .scalar(kind), start: token.start, end: token.end, firstToken: first, endToken: position)
        case .punctuation:
            guard token.text == "(" else { throw Failure() }
            position += 1
            let inner = try expression()
            try expect(")")
            var result = Expression(type: inner.type, start: token.start, end: tokens[position - 1].end, firstToken: first,
                                    endToken: position)
            result.isSimpleLValue = inner.isSimpleLValue
            return result
        case .identifier:
            break
        }
        position += 1
        if token.text == "true" || token.text == "false" {
            return Expression(type: .scalar(.bool), start: token.start, end: token.end, firstToken: first, endToken: position)
        }
        // A constructor: `vec3(…)`, `float[3](…)`, a struct's.
        if let constructed = type(named: token.text), !isDeclared(token.text) {
            var type = constructed
            if isPunctuation("["), let close = closing(from: position) {
                type = .array(type, nil)
                position = close + 1
            }
            guard isPunctuation("(") else { throw Failure() }
            _ = try callArguments()
            return Expression(type: type, start: token.start, end: tokens[position - 1].end, firstToken: first, endToken: position)
        }
        if isPunctuation("("), !isDeclared(token.text) {
            let arguments = try callArguments()
            let end = tokens[position - 1].end
            let type = call(token.text, arguments, start: token.start, end: end)
            return Expression(type: type, start: token.start, end: end, firstToken: first, endToken: position)
        }
        var result = Expression(type: lookup(token.text), start: token.start, end: token.end, firstToken: first, endToken: position)
        if case .opaque("?") = result.type { result.type = nil }
        result.isSimpleLValue = true
        return result
    }
}
