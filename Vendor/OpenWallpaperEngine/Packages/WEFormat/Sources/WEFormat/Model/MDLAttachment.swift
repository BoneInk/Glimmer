import simd

/// A named attachment point of the `MDAT0001` section (docs/models-plan.md §1.5): a scene
/// object's `attachment` names one and hangs from `bone` with `matrix` as its offset.
public struct MDLAttachment: Equatable {
    public var bone: UInt16
    public var name: String
    public var matrix: simd_float4x4

    public init(bone: UInt16, name: String, matrix: simd_float4x4) {
        self.bone = bone
        self.name = name
        self.matrix = matrix
    }
}
