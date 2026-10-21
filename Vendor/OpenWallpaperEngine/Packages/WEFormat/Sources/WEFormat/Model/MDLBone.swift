import simd

/// A bone of an `MDLS` skeleton (docs/models-plan.md §1.3).
///
/// Matrices in a `.mdl` are 16 floats of a D3D row-vector matrix with the translation in elements
/// 12…14. Read as four columns of four, that is the same memory as a column-major matrix acting on
/// column vectors, which is how every `simd_float4x4` of these types holds it: the translation is
/// `columns.3`.
public struct MDLBone: Equatable {
    public var name: String
    /// 0x1 marks an armature bone: WE's importer sets it on every bone of an FBX armature, weighted
    /// or not, and on every Puppet Warp bone, and leaves it off the other nodes it keeps (the
    /// scene's `RootNode`, the armature's object), which still get clip tracks, held at their bind
    /// (WE 2.8's capture 509 D). Nothing at run time reads it. 0x2 hangs the bone's constraints on
    /// its link, and WE then disables its clip tracks unless an IK set names it.
    public var flags: UInt32
    /// The parent's index, 0xFFFFFFFF for a root.
    public var parent: UInt32
    /// The bind transform relative to the parent.
    public var matrix: simd_float4x4
    /// The bone's physics and IK properties as JSON (`ik`, `se`, `gd`, `m`, `tf`…); empty when
    /// it has none.
    public var properties: String

    public var parentIndex: Int? { parent == 0xFFFF_FFFF ? nil : Int(parent) }

    public init(name: String, flags: UInt32, parent: UInt32, matrix: simd_float4x4, properties: String) {
        self.name = name
        self.flags = flags
        self.parent = parent
        self.matrix = matrix
        self.properties = properties
    }
}
