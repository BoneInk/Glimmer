import Metal
import simd

/// A pass's `WEUniforms` bytes: static values written once, dynamic constants and live built-ins
/// patched each frame. Avoids per-frame dictionaries and allocations on the render thread.
final class UniformProgram {
    private(set) var bytes: [UInt8]
    let size: Int
    /// True when only the live-bound constants can change between frames (no time, audio or
    /// pointer built-in): an output is reusable while their values (`appendDynamicValues`) stay.
    let isReusable: Bool
    let needsTextureInfo: Bool
    private let dynamic: [(member: UniformMember, constant: ShaderConstantResolver.DynamicConstant)]
    /// The user-bound dynamic constants, kept per binding revision.
    private var userConstants = SceneUserConstantCache()
    /// Members scripts can set, by the lower-cased scene.json key they answer to.
    private let scriptTargets: [String: [(member: UniformMember, binding: ShaderConstantResolver.ScriptBinding)]]
    /// Built-ins that only depend on the pass's targets and textures: written when those change.
    private let passBuiltins: [UniformMember]
    /// Built-ins that follow the placement or the camera (`BuiltinUniforms.Key.followsCamera`):
    /// written when those change, which a camera path or shake does every frame.
    private let cameraBuiltins: [(member: UniformMember, key: BuiltinUniforms.Key)]
    /// Reads `g_LayerModelMatrix`, which the chain's kept output depends on.
    let readsLayerModelMatrix: Bool
    /// Built-ins that change every frame (time, pointer, audio).
    private let frameBuiltins: [UniformMember]
    private var passSignature: [Float] = []
    private var cameraSignature: CameraSignature?

    /// What `cameraBuiltins` are computed from.
    private struct CameraSignature: Equatable {
        var modelViewProjection, modelMatrix, viewMatrix, viewProjection, effectTextureProjection: simd_float4x4
        var altModelMatrix, altViewProjection, layerModelMatrix: simd_float4x4?
        var eye, viewUp, viewRight, viewForward: SIMD3<Float>

        init(frame: BuiltinFrameContext, pass: BuiltinPassContext) {
            modelViewProjection = pass.modelViewProjection
            modelMatrix = pass.modelMatrix
            viewMatrix = pass.viewMatrix
            viewProjection = pass.viewProjection
            effectTextureProjection = pass.effectTextureProjection
            altModelMatrix = pass.altModelMatrix
            altViewProjection = pass.altViewProjection
            layerModelMatrix = pass.layerModelMatrix
            eye = frame.eyePosition
            viewUp = frame.viewUp
            viewRight = frame.viewRight
            viewForward = frame.viewForward
        }
    }

    /// Built-ins whose value changes from frame to frame (`g_HDRParams` follows the display's headroom).
    static let timeVarying: Set<String> = Set(["g_Time", "g_Frametime", "g_Daytime", "g_DayTime", "g_PointerPosition",
                                               "g_PointerPositionLast", "g_PointerState", "g_ParallaxPosition",
                                               "g_HDRParams"])
        .union(SceneFrameLighting.uniformNames)

    init(layout: UniformLayout?, constants: ShaderConstantResolver.ResolvedConstants) {
        size = layout?.size ?? 0
        bytes = [UInt8](repeating: 0, count: size)
        let dynamicByName = Dictionary(constants.dynamic.map { ($0.uniform, $0) }, uniquingKeysWith: { a, _ in a })
        var dynamic: [(UniformMember, ShaderConstantResolver.DynamicConstant)] = []
        var builtins: [UniformMember] = []
        for member in (layout?.members.values).map(Array.init) ?? [] {
            // A stage's own copy of a uniform (`ShaderUniformDeclaration.stageLocalNames`) takes
            // the shared value when its planner didn't resolve it apart.
            let shared = member.name.hasSuffix(ShaderUniformDeclaration.fragmentSuffix)
                ? String(member.name.dropLast(ShaderUniformDeclaration.fragmentSuffix.count)) : member.name
            if let constant = dynamicByName[member.name] ?? dynamicByName[shared] {
                dynamic.append((member, constant))
            } else if let value = constants.staticValues[member.name] ?? constants.staticValues[shared] {
                UniformWriter.write(value.components, member: member, into: &bytes)
            } else if BuiltinUniforms.isBuiltin(member.name) {
                builtins.append(member)
            }
        }
        self.dynamic = dynamic
        var scriptTargets: [String: [(member: UniformMember, binding: ShaderConstantResolver.ScriptBinding)]] = [:]
        let members = layout?.members ?? [:]
        for binding in constants.scriptBindings {
            guard let member = members[binding.uniform] else { continue }
            for key in Set(binding.keys) { scriptTargets[key, default: []].append((member, binding)) }
        }
        self.scriptTargets = scriptTargets
        let varies = { (member: UniformMember) in
            Self.timeVarying.contains(member.name) || member.name.hasPrefix("g_AudioSpectrum")
        }
        frameBuiltins = builtins.filter(varies)
        let fixed = builtins.filter { !varies($0) }
        let camera: [(member: UniformMember, key: BuiltinUniforms.Key)] = fixed.compactMap { member in
            BuiltinUniforms.Key(member.name).flatMap { $0.followsCamera ? (member, $0) : nil }
        }
        let cameraNames = Set(camera.map(\.member.name))
        cameraBuiltins = camera
        readsLayerModelMatrix = camera.contains { $0.key == .layerModelMatrix }
        passBuiltins = fixed.filter { !cameraNames.contains($0.name) }
        needsTextureInfo = builtins.contains { $0.name.hasPrefix("g_Texture") }
        isReusable = frameBuiltins.isEmpty
    }

    /// Hands `record` each animated constant's site and the floats its uniform holds (script writes
    /// included): what the GPU gets. Integer and matrix members aren't read back.
    func recordAnimated(_ record: (SceneAnimationSite, [Float]) -> Void) {
        for (member, constant) in dynamic {
            guard let site = constant.source.animationSite, member.type.hasPrefix("float") || member.type.hasPrefix("vec")
            else { continue }
            let count = min(constant.count, 4)
            guard member.offset + count * 4 <= bytes.count else { continue }
            let values = (0..<count).map { component in
                bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: member.offset + component * 4, as: Float.self) }
            }
            record(site, values)
        }
    }

    /// Appends the live-bound constants' values this frame, as `update` writes them.
    func appendDynamicValues(to values: inout [Float], values context: SceneValueContext) {
        userConstants.begin(dynamic.map(\.constant), in: context)
        for (index, (_, constant)) in dynamic.enumerated() {
            values += userConstants.value(index, of: constant, in: context).components
        }
    }

    /// Writes what scripts set (`setMaterialProperty`, `IMaterial` members) over the constants,
    /// in the order they were set: the last write of a key wins, as it does in the scripts.
    func write(_ scriptWrites: [SceneScriptConstantWrite]) {
        for write in scriptWrites {
            for (member, binding) in scriptTargets[write.name.lowercased()] ?? [] {
                let value = ShaderConstantResolver.shape(ShaderValue(components: write.value),
                                                         count: binding.count, isInt: binding.isInt)
                UniformWriter.write(value.components, member: member, into: &bytes)
            }
        }
    }

    func update(frame: BuiltinFrameContext, pass: BuiltinPassContext, values: SceneValueContext) {
        userConstants.begin(dynamic.map(\.constant), in: values)
        for (index, (member, constant)) in dynamic.enumerated() {
            UniformWriter.write(userConstants.value(index, of: constant, in: values).components, member: member, into: &bytes)
        }
        write(frameBuiltins, frame: frame, pass: pass)
        // Name lookups are string work; do them only when the targets actually change.
        var signature: [Float] = [frame.screenSize.x, frame.screenSize.y, pass.targetSize.x, pass.targetSize.y, pass.alpha,
                                  pass.color.x, pass.color.y, pass.color.z, frame.textureReductionScale]
        for slot in pass.textures.keys.sorted() {
            let info = pass.textures[slot]!
            signature += [Float(slot), info.allocatedSize.x, info.allocatedSize.y, info.contentSize.x, info.contentSize.y]
            if let rotation = info.spriteRotation, let translation = info.spriteTranslation {
                signature += [rotation.x, rotation.y, rotation.z, rotation.w, translation.x, translation.y]
            }
        }
        for index in pass.renderVars.keys.sorted() {
            let value = pass.renderVars[index]!
            signature += [Float(index), value.x, value.y, value.z, value.w]
        }
        if signature != passSignature {
            passSignature = signature
            write(passBuiltins, frame: frame, pass: pass)
        }
        guard !cameraBuiltins.isEmpty else { return }
        let camera = CameraSignature(frame: frame, pass: pass)
        if camera != cameraSignature {
            cameraSignature = camera
            for (member, key) in cameraBuiltins {
                UniformWriter.write(BuiltinUniforms.value(key, frame: frame, pass: pass), member: member, into: &bytes)
            }
        }
    }

    private func write(_ members: [UniformMember], frame: BuiltinFrameContext, pass: BuiltinPassContext) {
        for member in members {
            if let components = BuiltinUniforms.value(named: member.name, frame: frame, pass: pass,
                                                      arrayCount: member.count > 1 ? member.count : nil) {
                UniformWriter.write(components, member: member, into: &bytes)
            }
        }
    }
}
