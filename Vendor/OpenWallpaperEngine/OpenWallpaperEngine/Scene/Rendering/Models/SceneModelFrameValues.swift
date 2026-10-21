/// What the model draws of one frame share (`BuiltinFrameContext.serial`): the frame's built-ins
/// (time, pointer, lights, audio) and each material's bound constants are the same for every
/// object drawing that material, so they are resolved once a frame, not once a draw. A context
/// outside a frame (serial 0) resolves every time. Render thread only.
final class SceneModelFrameValues {
    private struct BuiltinSlot: Hashable {
        var key: BuiltinUniforms.Key
        var arrayCount: Int?
    }

    private var serial: UInt64 = 0
    private var builtins: [BuiltinSlot: [Float]] = [:]
    /// Per material (kept alive for the frame, so its identity can't be reused), each bound
    /// uniform's components.
    private var constants: [ObjectIdentifier: (material: AnyObject, values: [String: [Float]])] = [:]

    /// The frame's value of a built-in that reads nothing of the pass.
    func builtin(_ key: BuiltinUniforms.Key, arrayCount: Int?, frame: BuiltinFrameContext) -> [Float] {
        guard begin(frame) else {
            return BuiltinUniforms.value(key, frame: frame, pass: BuiltinPassContext(targetSize: frame.screenSize),
                                         arrayCount: arrayCount)
        }
        let slot = BuiltinSlot(key: key, arrayCount: arrayCount)
        if let known = builtins[slot] { return known }
        let value = BuiltinUniforms.value(key, frame: frame, pass: BuiltinPassContext(targetSize: frame.screenSize),
                                          arrayCount: arrayCount)
        builtins[slot] = value
        return value
    }

    /// `material`'s bound uniform `uniform` this frame, `resolve` on its first draw.
    func constant(of material: AnyObject, uniform: String, frame: BuiltinFrameContext, resolve: () -> [Float]) -> [Float] {
        guard begin(frame) else { return resolve() }
        let id = ObjectIdentifier(material)
        if let known = constants[id]?.values[uniform] { return known }
        let value = resolve()
        constants[id, default: (material, [:])].values[uniform] = value
        return value
    }

    /// Starts over on a new frame; false outside one.
    private func begin(_ frame: BuiltinFrameContext) -> Bool {
        guard frame.serial != 0 else { return false }
        if frame.serial != serial {
            serial = frame.serial
            builtins.removeAll(keepingCapacity: true)
            constants.removeAll(keepingCapacity: true)
        }
        return true
    }
}
