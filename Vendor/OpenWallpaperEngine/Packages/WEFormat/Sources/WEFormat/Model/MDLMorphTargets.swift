import Foundation

/// One mesh's morph targets (blend shapes) from the `MDMP0001` section (docs/models-plan.md
/// §1.5). No library file has the section; the layout is the reader's and the writer's, and WE's
/// editor wrote one for docs/test-risks.md MG5.
public struct MDLMorphTargets: Equatable {
    public struct Target: Equatable {
        /// The writer's `modifierbone`, `modifiermode`, `modifierstartdistance` and
        /// `modifierenddistance` (mesh flag 0x2000, `MORPHING_MODIFIERS`).
        public struct Modifier: Equatable {
            public var bone: UInt32
            public var mode: UInt32
            public var startDistance: Float
            public var endDistance: Float

            public init(bone: UInt32, mode: UInt32, startDistance: Float, endDistance: Float) {
                self.bone = bone
                self.mode = mode
                self.startDistance = startDistance
                self.endDistance = endDistance
            }
        }

        public var id: UInt64
        public var name: String
        /// A float3 per vertex, the position deltas over the mesh's `weight`: 16-bit signed
        /// normalised values, which WE copies as they are into its RGBA16 SNORM morph texture
        /// (format 0x13 → DXGI 13, 0x1400d2a4d; the editor's MG5 shape: 0x7FB1 · 126.47 / 32767 is
        /// its +126.168 x).
        public var positions: [Float]
        /// Mesh flag 0x400: normal deltas, like `positions` [I].
        public var normals: [Float]?
        /// Mesh flag 0x800: tangent deltas, like `positions` [I].
        public var tangents: [Float]?
        /// Mesh flag 0x1000: a 16-bit value per morph vertex, the texel's fourth (alpha) channel
        /// on puppets (the editor's mask alpha [I]).
        public var extra: Data?
        public var modifier: Modifier?

        public init(id: UInt64, name: String, positions: [Float], normals: [Float]? = nil, tangents: [Float]? = nil, extra: Data? = nil, modifier: Modifier? = nil) {
            self.id = id
            self.name = name
            self.positions = positions
            self.normals = normals
            self.tangents = tangents
            self.extra = extra
            self.modifier = modifier
        }
    }

    /// The mesh's index.
    public var mesh: Int
    /// With targets: WE's `g_MorphWeights[0]` (mesh+0x60), the scale the normalised deltas are
    /// multiplied by: the editor writes the largest delta's length (MG5: 126.47 for a shape moving
    /// one vertex by (126.168, 0, 8.7)).
    public var weight: Float?
    /// With targets: the vertices each target covers, clamped by WE to what the smallest position
    /// blob holds (0x14026578f).
    public var vertexCount: UInt32?
    public var targets: [Target]

    public init(mesh: Int, weight: Float? = nil, vertexCount: UInt32? = nil, targets: [Target]) {
        self.mesh = mesh
        self.weight = weight
        self.vertexCount = vertexCount
        self.targets = targets
    }
}

extension MDLMorphTargets {
    /// A 16-bit signed normalised value as the GPU reads it: `max(v / 32767, −1)`.
    public static func float(snormBits bits: UInt16) -> Float {
        max(Float(Int16(bitPattern: bits)) / 32767, -1)
    }

    /// `value` as 16-bit signed normalised bits, rounded to nearest and clamped to ±1: exact for
    /// the `.mdl`'s values, which `float(snormBits:)` read.
    public static func snormBits(_ value: Float) -> UInt16 {
        let scaled = (min(max(value, -1), 1) * 32767).rounded()
        return UInt16(bitPattern: Int16(scaled))
    }
}
