import Foundation

/// How the HLSL front end types a call to a GLSL built-in function and converts its arguments as
/// HLSL's intrinsic does: HLSL's intrinsics take any mix of scalars and vectors, which they bring
/// to one type (scalars splat, wider vectors truncate, ints convert), where GLSL's overloads want
/// the arguments to match.
enum HLSLBuiltins {
    enum Rule {
        /// Every argument is brought to one type, which is the result. `scalarParameters` may stay
        /// scalars where the others are vectors (GLSL has those overloads); `keepsIntegers`
        /// functions stay integer when every argument is.
        case componentwise(scalarParameters: Set<Int>, keepsIntegers: Bool)
        /// The arguments are brought to one float type; the result is a float.
        case reduces
        /// The arguments are brought to one type, which is the result (`normalize`, `reflect`),
        /// except the parameters listed, which are float scalars (`refract`'s ratio).
        case geometric(scalarParameters: Set<Int>)
        /// Both arguments become `vec3`.
        case cross
        /// The argument becomes a bool vector of its size (`all`, `any`); the result is a bool.
        case boolReduce
        /// The arguments are brought to one type; the result is a bool vector of its size.
        case compare
        /// `texture`-like: the coordinate (argument 1) becomes the sampler's coordinate size.
        case sample(result: SampleResult)
        /// A fixed result whatever the arguments.
        case fixed(HLSLType)
        /// The result is the first argument's type.
        case sameAsFirst
        /// The transpose of the argument.
        case transpose
    }

    enum SampleResult {
        case color
        case size
    }

    static let rules: [String: Rule] = {
        var rules: [String: Rule] = [:]
        let unary = ["radians", "degrees", "sin", "cos", "tan", "asin", "acos", "sinh", "cosh", "tanh", "asinh",
                     "acosh", "atanh", "exp", "log", "exp2", "log2", "sqrt", "inversesqrt", "floor", "trunc", "round",
                     "roundEven", "ceil", "fract", "dFdx", "dFdy", "fwidth", "dFdxFine", "dFdyFine", "dFdxCoarse",
                     "dFdyCoarse", "fwidthFine", "fwidthCoarse", "atan", "pow"]
        for name in unary { rules[name] = .componentwise(scalarParameters: [], keepsIntegers: false) }
        for name in ["abs", "sign"] { rules[name] = .componentwise(scalarParameters: [], keepsIntegers: true) }
        rules["min"] = .componentwise(scalarParameters: [1], keepsIntegers: true)
        rules["max"] = .componentwise(scalarParameters: [1], keepsIntegers: true)
        rules["clamp"] = .componentwise(scalarParameters: [1, 2], keepsIntegers: true)
        rules["mod"] = .componentwise(scalarParameters: [1], keepsIntegers: false)
        rules["mix"] = .componentwise(scalarParameters: [2], keepsIntegers: false)
        rules["step"] = .componentwise(scalarParameters: [0], keepsIntegers: false)
        rules["smoothstep"] = .componentwise(scalarParameters: [0, 1], keepsIntegers: false)
        rules["length"] = .reduces
        rules["distance"] = .reduces
        rules["dot"] = .reduces
        rules["normalize"] = .geometric(scalarParameters: [])
        rules["reflect"] = .geometric(scalarParameters: [])
        rules["faceforward"] = .geometric(scalarParameters: [])
        rules["refract"] = .geometric(scalarParameters: [2])
        rules["cross"] = .cross
        rules["all"] = .boolReduce
        rules["any"] = .boolReduce
        for name in ["lessThan", "lessThanEqual", "greaterThan", "greaterThanEqual", "equal", "notEqual"] {
            rules[name] = .compare
        }
        for name in ["texture", "textureLod", "textureGrad", "textureProj", "textureOffset", "textureLodOffset"] {
            rules[name] = .sample(result: .color)
        }
        rules["texelFetch"] = .fixed(.vector(.float, 4))
        rules["textureSize"] = .sample(result: .size)
        rules["determinant"] = .fixed(.scalar(.float))
        rules["inverse"] = .sameAsFirst
        rules["matrixCompMult"] = .sameAsFirst
        rules["not"] = .sameAsFirst
        rules["transpose"] = .transpose
        return rules
    }()

    /// The coordinate type of a sampler (`sampler2D` → `vec2`); nil for an unknown sampler.
    static func coordinate(of sampler: String) -> HLSLType? {
        switch sampler {
        case "sampler2D", "isampler2D", "usampler2D": return .vector(.float, 2)
        case "sampler3D", "samplerCube", "sampler2DShadow", "sampler2DArray": return .vector(.float, 3)
        case "samplerCubeShadow", "sampler2DArrayShadow": return .vector(.float, 4)
        case "sampler1D": return .scalar(.float)
        default: return nil
        }
    }

    /// GLSL's built-in variables WE shaders read or write.
    static let variables: [String: HLSLType] = [
        "gl_Position": .vector(.float, 4), "gl_FragCoord": .vector(.float, 4), "gl_FragDepth": .scalar(.float),
        "gl_PointSize": .scalar(.float), "gl_VertexID": .scalar(.int), "gl_InstanceID": .scalar(.int),
        "gl_VertexIndex": .scalar(.int), "gl_InstanceIndex": .scalar(.int), "gl_FrontFacing": .scalar(.bool),
        "gl_PointCoord": .vector(.float, 2), "gl_ViewportIndex": .scalar(.int), "gl_Layer": .scalar(.int),
    ]
}
