import simd

/// The `WEUniforms` bytes of one mesh's material (docs/models-plan.md §2.7): its constants
/// written once, its bound constants and the time-varying built-ins (lights included) every draw,
/// the built-ins that depend on where the model is drawn (`g_ModelMatrix`, `g_NormalModelMatrix`,
/// `g_ViewProjectionMatrix`, `g_EyePosition`, the texture sizes…) only when that changes, and the
/// bones slot (`g_Bones`, `BONECOUNT` × `mat4x3`) whenever the pose does.
///
/// A model's material takes nothing from its object: WE doesn't read `color`, `alpha` or
/// `brightness` on models (§2.6), so `g_Brightness`, `g_TintColor` and the like are the
/// material's own constants.
final class ModelMaterialUniforms {
    /// What the placement-dependent built-ins are computed from.
    struct PassKey: Equatable {
        var world: simd_float4x4
        var view: simd_float4x4
        var viewProjection: simd_float4x4
        var eye: SIMD3<Float>
        var screen: SIMD2<Float>
        var target: SIMD2<Float>
        /// Per bound slot: allocated width/height, content width/height.
        var textures: [SIMD4<Float>]
    }

    private(set) var bytes: [UInt8]
    let size: Int
    private let dynamic: [(member: UniformMember, constant: ShaderConstantResolver.DynamicConstant)]
    /// The built-ins, resolved once: those that change every frame (which read nothing of the
    /// pass) and those that change with the placement.
    private let frameBuiltins: [(member: UniformMember, key: BuiltinUniforms.Key)]
    private let passBuiltins: [(member: UniformMember, key: BuiltinUniforms.Key)]
    private let bones: UniformMember?
    private let layout: UniformLayout?
    private var lastKey: PassKey?
    private var lastBones: [Float]?
    /// The first bone of `g_Bones` from which every bone holds the identity.
    private var identityFrom = 0

    init(layout: UniformLayout?, constants: ShaderConstantResolver.ResolvedConstants) {
        size = layout?.size ?? 0
        self.layout = layout
        bytes = [UInt8](repeating: 0, count: size)
        let dynamicByName = Dictionary(constants.dynamic.map { ($0.uniform, $0) }, uniquingKeysWith: { a, _ in a })
        var dynamic: [(UniformMember, ShaderConstantResolver.DynamicConstant)] = []
        var builtins: [(member: UniformMember, key: BuiltinUniforms.Key)] = []
        for member in (layout?.members.values).map(Array.init) ?? [] {
            if let constant = dynamicByName[member.name] {
                dynamic.append((member, constant))
            } else if let value = constants.staticValues[member.name] {
                UniformWriter.write(value.components, member: member, into: &bytes)
            } else if BuiltinUniforms.isBuiltin(member.name), let key = BuiltinUniforms.Key(member.name) {
                builtins.append((member, key))
            }
        }
        self.dynamic = dynamic
        let varies = { (member: UniformMember) in
            UniformProgram.timeVarying.contains(member.name) || member.name.hasPrefix("g_AudioSpectrum")
        }
        frameBuiltins = builtins.filter { varies($0.member) }
        passBuiltins = builtins.filter { !varies($0.member) }
        bones = layout?.members["g_Bones"]
        // The bind pose until the first pose arrives: every bone the identity.
        if let bones { UniformWriter.write(Self.identityBones(count: bones.count), member: bones, into: &bytes) }
    }

    /// Writes this draw's values. `pass` builds the pass context; it runs only when needed.
    /// `shared` resolves the frame's built-ins and the bound constants of `material` (whose
    /// constants these are) once a frame for every draw of it.
    func update(key: PassKey, frame: BuiltinFrameContext, values: SceneValueContext,
                shared: (values: SceneModelFrameValues, material: AnyObject)? = nil, pass: () -> BuiltinPassContext) {
        for (member, constant) in dynamic {
            let resolve: () -> [Float] = {
                ShaderConstantResolver.shape(SceneValueResolver.resolve(constant.source, in: values),
                                             count: constant.count, isInt: constant.isInt).components
            }
            let components = shared.map { $0.values.constant(of: $0.material, uniform: constant.uniform, frame: frame,
                                                             resolve: resolve) } ?? resolve()
            UniformWriter.write(components, member: member, into: &bytes)
        }
        // The frame's built-ins read nothing of the pass, which is made only when the placement changed.
        for (member, builtin) in frameBuiltins {
            let arrayCount = member.count > 1 ? member.count : nil
            let components = shared?.values.builtin(builtin, arrayCount: arrayCount, frame: frame)
                ?? BuiltinUniforms.value(builtin, frame: frame, pass: BuiltinPassContext(targetSize: key.target),
                                         arrayCount: arrayCount)
            UniformWriter.write(components, member: member, into: &bytes)
        }
        if key != lastKey {
            lastKey = key
            write(passBuiltins, frame: frame, pass: pass())
        }
    }

    /// The bones slot: `g_Bones` as `mat4x3` components (per bone the four columns' x, y and z of
    /// `boneWorld · inverseBind`, `ScenePuppetPose.boneComponents`), padded with identities to the
    /// shader's `BONECOUNT`. Nothing to do for a material without skinning.
    func writeBones(_ components: [Float]) {
        guard let bones, components != lastBones else { return }
        lastBones = components
        // The writer stops at the shader's `BONECOUNT`. The bones after the pose's are identities
        // from the bind pose on, unless a larger pose wrote them since.
        UniformWriter.write(components, member: bones, into: &bytes)
        let count = min(components.count / 12, bones.count)
        if count < identityFrom {
            let tail = UniformMember(name: bones.name, type: bones.type, offset: bones.offset + count * bones.arrayStride,
                                     count: identityFrom - count, arrayStride: bones.arrayStride,
                                     matrixStride: bones.matrixStride)
            UniformWriter.write(Self.identityBones(count: tail.count), member: tail, into: &bytes)
        }
        identityFrom = count
    }

    /// The morph uniforms (`g_MorphOffsets`, `g_MorphWeights`) of a `MORPHING` mesh.
    func writeMorphs(_ morph: SceneMorphUniforms) {
        guard let layout else { return }
        morph.write(into: &bytes, layout: layout)
    }

    /// Writes an engine value the material doesn't set and the built-ins don't cover (the shadow
    /// variant's `g_ViewportViewProjectionMatrices`); false when the layout has no such member.
    @discardableResult
    func write(_ components: [Float], member name: String) -> Bool {
        guard let member = layout?.members[name] else { return false }
        UniformWriter.write(components, member: member, into: &bytes)
        return true
    }

    private func write(_ members: [(member: UniformMember, key: BuiltinUniforms.Key)], frame: BuiltinFrameContext,
                       pass: BuiltinPassContext) {
        for (member, key) in members {
            let components = BuiltinUniforms.value(key, frame: frame, pass: pass, arrayCount: member.count > 1 ? member.count : nil)
            UniformWriter.write(components, member: member, into: &bytes)
        }
    }

    static func identityBones(count: Int) -> [Float] {
        Array([[Float]](repeating: [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], count: max(count, 0)).joined())
    }
}
