import simd

/// The `WEUniforms` bytes of an image material: constants written once, dynamic constants and
/// time-varying built-ins every draw, and the built-ins that depend on the layer's placement,
/// colour and textures only when those change (a still layer rewrites nothing).
final class ImageMaterialUniforms {
    /// What the placement-dependent built-ins are computed from.
    struct PassKey: Equatable {
        var model: simd_float4x4
        var viewProjection: simd_float4x4
        var color: SIMD3<Float>
        var alpha: Float
        var brightness: Float
        var spriteRotation: SIMD4<Float>
        var spriteTranslation: SIMD2<Float>
        var screen: SIMD2<Float>
        /// Per bound slot: allocated width/height, content width/height.
        var textures: [SIMD4<Float>]
        /// The sprite frames of the animated asset textures bound, in slot order.
        var sprites: [BuiltinSpriteFrame] = []
    }

    private(set) var bytes: [UInt8]
    let size: Int
    private let dynamic: [(member: UniformMember, constant: ShaderConstantResolver.DynamicConstant)]
    /// The user-bound dynamic constants, kept per binding revision.
    private var userConstants = SceneUserConstantCache()
    private let frameBuiltins: [UniformMember]
    private let passBuiltins: [UniformMember]
    /// `g_Brightness` and `g_UserAlpha` scaled by the material's own value.
    private let liveFactors: [String: Float]
    private var lastKey: PassKey?

    init(layout: UniformLayout?, constants: ShaderConstantResolver.ResolvedConstants, liveFactors: [String: Float]) {
        size = layout?.size ?? 0
        bytes = [UInt8](repeating: 0, count: size)
        self.liveFactors = liveFactors
        let dynamicByName = Dictionary(constants.dynamic.map { ($0.uniform, $0) }, uniquingKeysWith: { a, _ in a })
        var dynamic: [(UniformMember, ShaderConstantResolver.DynamicConstant)] = []
        var builtins: [UniformMember] = []
        for member in (layout?.members.values).map(Array.init) ?? [] {
            if let constant = dynamicByName[member.name] {
                dynamic.append((member, constant))
            } else if let value = constants.staticValues[member.name] {
                UniformWriter.write(value.components, member: member, into: &bytes)
            } else if BuiltinUniforms.isBuiltin(member.name) {
                builtins.append(member)
            }
        }
        self.dynamic = dynamic
        let varies = { (member: UniformMember) in
            UniformProgram.timeVarying.contains(member.name) || member.name.hasPrefix("g_AudioSpectrum")
        }
        frameBuiltins = builtins.filter(varies)
        passBuiltins = builtins.filter { !varies($0) }
    }

    /// Writes this draw's values. `pass` builds the pass context; it runs only when `key` changed.
    func update(key: PassKey, frame: BuiltinFrameContext, values: SceneValueContext, pass: () -> BuiltinPassContext) {
        userConstants.begin(dynamic.map(\.constant), in: values)
        for (index, (member, constant)) in dynamic.enumerated() {
            UniformWriter.write(userConstants.value(index, of: constant, in: values).components, member: member, into: &bytes)
        }
        let placementChanged = key != lastKey
        guard !frameBuiltins.isEmpty || placementChanged else { return }
        let context = pass()
        write(frameBuiltins, frame: frame, pass: context)
        if placementChanged {
            lastKey = key
            write(passBuiltins, frame: frame, pass: context)
        }
    }

    private func write(_ members: [UniformMember], frame: BuiltinFrameContext, pass: BuiltinPassContext) {
        for member in members {
            guard var components = BuiltinUniforms.value(named: member.name, frame: frame, pass: pass,
                                                         arrayCount: member.count > 1 ? member.count : nil) else { continue }
            components = Self.live(member.name, components, pass: pass, factors: liveFactors)
            UniformWriter.write(components, member: member, into: &bytes)
        }
    }

    /// WE's image shaders take the layer's colour, alpha and brightness through these: the
    /// `VERSION` shaders multiply the texel by `g_Color4`, which carries the brightness too
    /// (they have no `g_Brightness`); the older ones scale by `g_Brightness` and `g_UserAlpha`.
    static func live(_ name: String, _ components: [Float], pass: BuiltinPassContext,
                     factors: [String: Float]) -> [Float] {
        switch name {
        case "g_Color4":
            let rgb = pass.color * pass.brightness
            return [rgb.x, rgb.y, rgb.z, pass.alpha]
        case "g_Brightness", "g_UserAlpha":
            return components.map { $0 * (factors[name] ?? 1) }
        default:
            return components
        }
    }
}
