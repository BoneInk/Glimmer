import Foundation

extension HLSLConversionPass {
    /// Types the call `name(arguments)` spanning `start..<end` and converts its arguments: `mul`,
    /// the shader's own functions (HLSL's overload resolution), then GLSL's built-ins.
    mutating func call(_ name: String, _ arguments: [Expression], start: Int, end: Int) -> HLSLType? {
        let overloads = (functions[name] ?? []).filter { $0.parameters.count == arguments.count }
        if name == "mul", arguments.count == 2, overloads.isEmpty {
            return multiply(arguments[0], arguments[1], start: start, end: end)
        }
        if let exact = overloads.first(where: { signature in
            zip(signature.parameters, arguments).allSatisfy { $0.type == nil || $1.type == nil || $0.type == $1.type }
        }) {
            return exact.returnType
        }
        // A built-in's own overloads take any arguments HLSL's intrinsic takes, ahead of the
        // shader's inexact overloads of it.
        if let rule = HLSLBuiltins.rules[name] {
            return builtin(rule, arguments)
        }
        guard !overloads.isEmpty else { return nil }
        return userCall(overloads, arguments)
    }

    /// The overload HLSL picks (every argument converts implicitly, the cheapest in total), with
    /// its input arguments converted; nil when none or several fit.
    mutating func userCall(_ overloads: [Signature], _ arguments: [Expression]) -> HLSLType? {
        var best: (signature: Signature, cost: Int)?
        var tied = false
        for signature in overloads {
            var total = 0
            var fits = true
            for (parameter, argument) in zip(signature.parameters, arguments) {
                guard let to = parameter.type, let from = argument.type else { continue }
                let isOutput = parameter.qualifier == "out" || parameter.qualifier == "inout"
                guard let cost = HLSLConversion.cost(from: from, to: to), !(isOutput && cost > 0) else { fits = false; break }
                total += cost
            }
            guard fits else { continue }
            if let current = best {
                if total < current.cost { best = (signature, total); tied = false } else if total == current.cost { tied = true }
            } else {
                best = (signature, total)
            }
        }
        guard let best, !tied else { return nil }
        for (parameter, argument) in zip(best.signature.parameters, arguments) {
            guard let type = parameter.type, parameter.qualifier != "out", parameter.qualifier != "inout" else { continue }
            convert(argument, to: type)
        }
        return best.signature.returnType
    }

    /// HLSL's `mul(a, b)`: a row vector times a matrix is GLSL's matrix times a column vector,
    /// as WE's matrices are laid out, so the operands swap: `mul(v, M)` → `M * v`, `mul(M, v)` →
    /// `v * M`, `mul(A, B)` → `B * A`. A vector wider than the matrix truncates, and two vectors
    /// make a dot product, as in HLSL.
    mutating func multiply(_ a: Expression, _ b: Expression, start: Int, end: Int) -> HLSLType? {
        var type: HLSLType?
        var function: String?
        switch (a.type, b.type) {
        case (.vector(_, let n)?, .matrix(let c, let r)?):
            if n > c { convert(a, to: .vector(.float, c)) }
            type = n >= c ? .vector(.float, r) : nil
        case (.matrix(let c, let r)?, .vector(_, let n)?):
            if n > r { convert(b, to: .vector(.float, r)) }
            type = n >= r ? .vector(.float, c) : nil
        case (.matrix(let c, let r)?, .matrix(let c2, let r2)?):
            type = c2 == r ? .matrix(columns: c, rows: r2) : nil
        case (.vector(_, let n)?, .vector(_, let m)?):
            let size = min(n, m)
            convert(a, to: .vector(.float, size))
            convert(b, to: .vector(.float, size))
            function = "dot"
            type = .scalar(.float)
        case (.scalar?, let other?), (let other?, .scalar?):
            type = other.withKind(.float)
        default:
            type = nil
        }
        let left = edits.render(code, a.start, a.end, consume: true)
        let right = edits.render(code, b.start, b.end, consume: true)
        if let function {
            edits.replace(start, end, "\(function)(\(left), \(right))")
        } else {
            edits.replace(start, end, "((\(right)) * (\(left)))")
        }
        return type
    }

    /// A GLSL built-in's result, its arguments brought to the types HLSL's intrinsic gives them.
    mutating func builtin(_ rule: HLSLBuiltins.Rule, _ arguments: [Expression]) -> HLSLType? {
        let types = arguments.map(\.type)
        switch rule {
        case .componentwise(let scalarParameters, let keepsIntegers):
            // `mix(a, b, bool)` selects (GLSL's mix with a bool vector).
            if arguments.count == 3, types[2]?.scalarKind == .bool, let a = types[0], let b = types[1],
               let common = HLSLConversion.componentwise(a, b) {
                let result = common.withKind(.float)
                convert(arguments[0], to: result)
                convert(arguments[1], to: result)
                convert(arguments[2], to: result.withKind(.bool))
                return result
            }
            guard let common = unify(types, float: !keepsIntegers) else { return nil }
            for (index, argument) in arguments.enumerated() {
                guard let type = argument.type else { continue }
                let target = type.components == 1 && scalarParameters.contains(index) ? .scalar(common.scalarKind!) : common
                convert(argument, to: target)
            }
            return common
        case .reduces:
            guard let common = unify(types, float: true) else { return arguments.isEmpty ? nil : .scalar(.float) }
            for argument in arguments { convert(argument, to: common) }
            return .scalar(.float)
        case .geometric(let scalarParameters):
            let vectors = types.enumerated().filter { !scalarParameters.contains($0.offset) }.map(\.element)
            guard let common = unify(vectors, float: true) else { return nil }
            for (index, argument) in arguments.enumerated() {
                convert(argument, to: scalarParameters.contains(index) ? .scalar(.float) : common)
            }
            return common
        case .cross:
            for argument in arguments { convert(argument, to: .vector(.float, 3)) }
            return .vector(.float, 3)
        case .boolReduce:
            guard let type = types.first ?? nil, let n = type.components, n > 1 else { return .scalar(.bool) }
            convert(arguments[0], to: .vector(.bool, n))
            return .scalar(.bool)
        case .compare:
            guard let common = unify(types, float: false), let n = common.components else { return nil }
            for argument in arguments { convert(argument, to: common) }
            return .vector(.bool, n)
        case .sample(let result):
            guard let sampler = types.first ?? nil, case .opaque(let name) = sampler else {
                return result == .color ? .vector(.float, 4) : nil
            }
            if result == .size { return name.hasSuffix("3D") ? .vector(.int, 3) : .vector(.int, 2) }
            if arguments.count > 1, let coordinate = HLSLBuiltins.coordinate(of: name) {
                convert(arguments[1], to: coordinate)
            }
            return name.hasSuffix("Shadow") ? .scalar(.float) : .vector(.float, 4)
        case .fixed(let type):
            return type
        case .sameAsFirst:
            return types.first ?? nil
        case .transpose:
            guard case .matrix(let c, let r)? = types.first ?? nil else { return nil }
            return .matrix(columns: r, rows: c)
        }
    }

    /// The one type HLSL brings scalars and vectors to: the narrowest vector (scalars splat), the
    /// highest kind, or float when `float`. Nil when an argument isn't a scalar or vector.
    func unify(_ types: [HLSLType?], float: Bool) -> HLSLType? {
        var result: HLSLType?
        for type in types {
            guard let type, type.isScalarOrVector else { return nil }
            result = result.map { HLSLConversion.componentwise($0, type)! } ?? type
        }
        guard var unified = result else { return nil }
        if float || unified.scalarKind == .bool { unified = unified.withKind(.float) }
        return unified
    }
}
