import Foundation

/// A mesh's vertices as two streams: the position alone, then every other attribute interleaved.
/// A pass that reads only the position (a shadow caster's depth, which most are) then fetches
/// only its bytes per vertex instead of the whole interleaved vertex; a pass that reads more
/// fetches both streams, the same bytes as before. A format with only a position, or none, stays
/// one stream.
struct SceneModelVertexStreams: Equatable {
    /// The position attribute, first in the vertex (`MDLVertexAttribute.all` order).
    let position: MDLVertexAttribute
    /// Bytes per vertex in each stream.
    let positionStride: Int
    let attributeStride: Int

    init?(_ format: MDLVertexFormat) {
        let elements = format.elements
        guard let first = elements.first, first.attribute == .position || first.attribute == .positionVec4,
              first.offset == 0, elements.count > 1 else { return nil }
        position = first.attribute
        positionStride = first.attribute.byteSize
        attributeStride = format.stride - positionStride
        guard attributeStride > 0 else { return nil }
    }

    /// Where `attribute` is read from: 0 for the position stream, 1 for the attributes, and its
    /// offset in that stream's vertex.
    func location(of attribute: MDLVertexAttribute, in format: MDLVertexFormat) -> (stream: Int, offset: Int)? {
        if attribute == position { return (0, 0) }
        guard let offset = format.offset(of: attribute) else { return nil }
        return (1, offset - positionStride)
    }

    /// Splits interleaved `vertices` (whole vertices of `positionStride + attributeStride` bytes)
    /// into the two streams' storage, which must hold `vertexCount` vertices each.
    func split(_ vertices: UnsafeRawBufferPointer, positions: UnsafeMutableRawPointer, attributes: UnsafeMutableRawPointer) {
        let stride = positionStride + attributeStride
        guard let base = vertices.baseAddress else { return }
        for vertex in 0..<(vertices.count / stride) {
            let source = base + vertex * stride
            (positions + vertex * positionStride).copyMemory(from: source, byteCount: positionStride)
            (attributes + vertex * attributeStride).copyMemory(from: source + positionStride, byteCount: attributeStride)
        }
    }
}
