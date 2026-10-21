import Foundation

/// A mesh's vertex format: which of the 26 attributes (`MDLVertexAttribute.all`) each vertex
/// carries, interleaved in table order (docs/models-plan.md §1.2). `MDLV` before version 15 has
/// one format for the whole file; later versions one per mesh.
public struct MDLVertexFormat: Hashable, CustomStringConvertible {
    /// An attribute and its byte offset in the vertex.
    public struct Element: Hashable {
        public let attribute: MDLVertexAttribute
        public let offset: Int

        public init(attribute: MDLVertexAttribute, offset: Int) {
            self.attribute = attribute
            self.offset = offset
        }
    }

    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Every bit WE's table knows.
    public static let knownBits: UInt32 = MDLVertexAttribute.all.reduce(0) { $0 | $1.mask }

    /// Bits outside WE's table (a format the reader can't lay out).
    public var unknownBits: UInt32 { rawValue & ~Self.knownBits }

    /// The attributes present, with their offsets, in interleaving order.
    public var elements: [Element] {
        var offset = 0
        var out: [Element] = []
        for attribute in MDLVertexAttribute.all where rawValue & attribute.mask != 0 {
            out.append(Element(attribute: attribute, offset: offset))
            offset += attribute.byteSize
        }
        return out
    }

    /// Bytes per vertex (0x140261a3a..0x140261b2b).
    public var stride: Int {
        MDLVertexAttribute.all.reduce(0) { rawValue & $1.mask != 0 ? $0 + $1.byteSize : $0 }
    }

    public func contains(_ attribute: MDLVertexAttribute) -> Bool { rawValue & attribute.mask != 0 }

    /// The byte offset of `attribute` in a vertex, nil when the format lacks it.
    public func offset(of attribute: MDLVertexAttribute) -> Int? {
        elements.first { $0.attribute == attribute }?.offset
    }

    public var description: String { "0x" + String(rawValue, radix: 16) }
}
