import Foundation

/// A GLSL type as the HLSL front end tracks it.
indirect enum HLSLType: Equatable {
    enum Scalar: String {
        case float, int, uint, bool

        /// HLSL's promotion order: an operation on two kinds takes the later one.
        var rank: Int {
            switch self {
            case .bool: return 0
            case .int: return 1
            case .uint: return 2
            case .float: return 3
            }
        }
    }

    case scalar(Scalar)
    case vector(Scalar, Int)
    /// GLSL `matCxR`: `columns` vectors of `rows` floats.
    case matrix(columns: Int, rows: Int)
    case structure(String)
    /// Samplers and the HLSL stream types of geometry stages.
    case opaque(String)
    case array(HLSLType, Int?)
    case void

    /// The type a GLSL type name denotes; `structs` are the struct names declared so far.
    static func named(_ name: String, structs: Set<String>) -> HLSLType? {
        if let scalar = Scalar(rawValue: name) { return .scalar(scalar) }
        if name == "void" { return .void }
        if structs.contains(name) { return .structure(name) }
        if name.hasPrefix("sampler") { return .opaque(name) }
        let prefixes: [(String, Scalar)] = [("vec", .float), ("ivec", .int), ("uvec", .uint), ("bvec", .bool)]
        for (prefix, scalar) in prefixes where name.hasPrefix(prefix) {
            if let n = Int(name.dropFirst(prefix.count)), (2...4).contains(n) { return .vector(scalar, n) }
            return nil
        }
        if name.hasPrefix("mat") {
            let size = name.dropFirst(3)
            let parts = size.split(separator: "x")
            if parts.count == 1, let n = Int(parts[0]), (2...4).contains(n) { return .matrix(columns: n, rows: n) }
            if parts.count == 2, let c = Int(parts[0]), let r = Int(parts[1]), (2...4).contains(c), (2...4).contains(r) {
                return .matrix(columns: c, rows: r)
            }
        }
        return nil
    }

    /// The GLSL name of a scalar, vector or matrix type.
    var glslName: String? {
        switch self {
        case .scalar(let scalar): return scalar.rawValue
        case .vector(let scalar, let n):
            let prefix = ["float": "", "int": "i", "uint": "u", "bool": "b"][scalar.rawValue]!
            return "\(prefix)vec\(n)"
        case .matrix(let c, let r): return c == r ? "mat\(c)" : "mat\(c)x\(r)"
        default: return nil
        }
    }

    var scalarKind: Scalar? {
        switch self {
        case .scalar(let scalar), .vector(let scalar, _): return scalar
        case .matrix: return .float
        default: return nil
        }
    }

    /// Components of a scalar (1) or vector; nil for anything else.
    var components: Int? {
        switch self {
        case .scalar: return 1
        case .vector(_, let n): return n
        default: return nil
        }
    }

    var isScalarOrVector: Bool { components != nil }

    /// A scalar or vector of `kind` with `components` components.
    static func numeric(_ kind: Scalar, _ components: Int) -> HLSLType {
        components == 1 ? .scalar(kind) : .vector(kind, components)
    }

    func withKind(_ kind: Scalar) -> HLSLType {
        switch self {
        case .scalar: return .scalar(kind)
        case .vector(_, let n): return .vector(kind, n)
        default: return self
        }
    }
}

/// HLSL's implicit conversions (FXC, which compiles WE's shaders: `wallpaper64.exe` maps the GLSL
/// type names onto HLSL's at 0x486b10 and calls `D3DCompile`), as GLSL constructors.
enum HLSLConversion {
    /// GLSL converts these kinds implicitly (GLSL 4.50 §4.1.10): int to uint, int or uint to float.
    static func isImplicitInGLSL(_ from: HLSLType.Scalar, _ to: HLSLType.Scalar) -> Bool {
        from == to || (from == .int && to == .uint) || (from == .int && to == .float) || (from == .uint && to == .float)
    }

    /// The constructor that converts a value of `from` to `to` as HLSL converts it implicitly: a
    /// scalar splats to a vector, a wider vector truncates (to a scalar: its first component), a
    /// larger matrix keeps its top-left, and kinds convert. Nil when no conversion is needed, or
    /// when HLSL has none that GLSL can express (a narrower vector widening, a scalar filling a
    /// matrix, which GLSL's constructor would make diagonal).
    static func constructor(from: HLSLType, to: HLSLType) -> String? {
        guard from != to else { return nil }
        switch (from, to) {
        case (.scalar(let a), .scalar(let b)):
            return isImplicitInGLSL(a, b) ? nil : to.glslName
        case (.scalar, .vector), (.vector, .scalar):
            return to.glslName
        case (.vector(let a, let n), .vector(let b, let m)):
            if m > n { return nil }
            if m == n, isImplicitInGLSL(a, b) { return nil }
            return to.glslName
        case (.matrix(let c, let r), .matrix(let tc, let tr)):
            return tc <= c && tr <= r ? to.glslName : nil
        default:
            return nil
        }
    }

    /// Relative cost of converting `from` to `to` when choosing between overloads: nil when there
    /// is no implicit conversion.
    static func cost(from: HLSLType, to: HLSLType) -> Int? {
        if from == to { return 0 }
        switch (from, to) {
        case (.scalar(let a), .scalar(let b)): return isImplicitInGLSL(a, b) ? 1 : 2
        case (.scalar, .vector): return 3
        case (.vector(let a, let n), .vector(let b, let m)):
            if m > n { return nil }
            if m == n { return isImplicitInGLSL(a, b) ? 1 : 2 }
            return 4
        case (.vector, .scalar): return 5
        case (.matrix(let c, let r), .matrix(let tc, let tr)): return tc <= c && tr <= r ? 4 : nil
        default: return nil
        }
    }

    /// The kind an operation on `a` and `b` works in (HLSL promotes to the higher rank).
    static func promoted(_ a: HLSLType.Scalar, _ b: HLSLType.Scalar) -> HLSLType.Scalar {
        a.rank >= b.rank ? a : b
    }

    /// The type both operands of a component-wise operation take: vectors truncate to the
    /// narrowest, scalars stay scalars (GLSL splats them for operators), kinds promote. Nil
    /// unless both are scalars or vectors.
    static func componentwise(_ a: HLSLType, _ b: HLSLType) -> HLSLType? {
        guard let n = a.components, let m = b.components, let ka = a.scalarKind, let kb = b.scalarKind else { return nil }
        let kind = promoted(ka, kb)
        if n == 1 && m == 1 { return .scalar(kind) }
        let size = n == 1 ? m : (m == 1 ? n : min(n, m))
        return .vector(kind, size)
    }
}
