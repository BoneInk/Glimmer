import Foundation

/// One of the 26 vertex attributes a `.mdl` mesh's format bits select (docs/models-plan.md §1.2):
/// WE's tables at 0x140484a20 (mask), 0x1404849b0 (byte size), 0x140484a90 (GLSL name) and
/// 0x140482af0 (D3D11 input element: semantic, index, DXGI format).
public struct MDLVertexAttribute: Hashable, CustomStringConvertible {
    public enum ComponentType: Hashable {
        case float32
        /// `a_BlendIndices`: R32G32B32A32_UINT.
        case uint32
    }

    /// The format bit.
    public let mask: UInt32
    /// The GLSL input name the shaders declare (`a_Position`, `a_TexCoordVec4C2`, …).
    public let name: String
    public let semantic: String
    public let semanticIndex: Int
    public let componentType: ComponentType
    public let components: Int

    public var byteSize: Int { 4 * components }
    public var description: String { name }

    /// Every attribute in WE's table order, which is the order they are interleaved in a vertex
    /// (the input layout accumulates offsets in this order, 0x1400d81c6), not bit order.
    public static let all: [MDLVertexAttribute] = {
        var table: [MDLVertexAttribute] = [
            .init(mask: 0x1, name: "a_Position", semantic: "POSITION", semanticIndex: 0, componentType: .float32, components: 3),
            // w is the morph index; selects MORPHING (0x14020730c).
            .init(mask: 0x10000, name: "a_PositionVec4", semantic: "POSITION", semanticIndex: 0, componentType: .float32, components: 4),
            .init(mask: 0x2000000, name: "a_PositionC1", semantic: "POSITION", semanticIndex: 1, componentType: .float32, components: 3),
            .init(mask: 0x2, name: "a_Normal", semantic: "NORMAL", semanticIndex: 0, componentType: .float32, components: 3),
            // xyz and the handedness in w.
            .init(mask: 0x4, name: "a_Tangent4", semantic: "TANGENT", semanticIndex: 0, componentType: .float32, components: 4),
            .init(mask: 0x800000, name: "a_BlendIndices", semantic: "BLENDINDICES", semanticIndex: 0, componentType: .uint32, components: 4),
            .init(mask: 0x1000000, name: "a_BlendWeights", semantic: "BLENDWEIGHT", semanticIndex: 0, componentType: .float32, components: 4),
        ]
        // a_TexCoord{,Vec3,Vec4} then C1…C5, each a float2, float3 and float4.
        let channels: [(suffix: String, masks: [UInt32])] = [
            ("", [0x8, 0x10, 0x20]), ("C1", [0x40, 0x80, 0x100]), ("C2", [0x200, 0x400, 0x800]),
            ("C3", [0x1000, 0x2000, 0x4000]), ("C4", [0x20000, 0x40000, 0x80000]), ("C5", [0x100000, 0x200000, 0x400000]),
        ]
        for (index, channel) in channels.enumerated() {
            for (kind, mask) in zip(["", "Vec3", "Vec4"], channel.masks) {
                table.append(.init(mask: mask, name: "a_TexCoord" + kind + channel.suffix, semantic: "TEXCOORD",
                                   semanticIndex: index, componentType: .float32, components: kind == "" ? 2 : kind == "Vec3" ? 3 : 4))
            }
        }
        // Always last.
        table.append(.init(mask: 0x8000, name: "a_Color", semantic: "COLOR", semanticIndex: 0, componentType: .float32, components: 4))
        return table
    }()

    public static let position = all[0]
    public static let positionVec4 = all[1]
    public static let normal = all[3]
    public static let tangent4 = all[4]
    public static let blendIndices = all[5]
    public static let blendWeights = all[6]
    public static let texCoord = all[7]
    public static let color = all[25]

    /// The attribute with that GLSL name.
    public static func named(_ name: String) -> MDLVertexAttribute? { all.first { $0.name == name } }

    public init(mask: UInt32, name: String, semantic: String, semanticIndex: Int, componentType: ComponentType, components: Int) {
        self.mask = mask
        self.name = name
        self.semantic = semantic
        self.semanticIndex = semanticIndex
        self.componentType = componentType
        self.components = components
    }
}
