import XCTest
@testable import OpenWallpaperEngine

final class SceneModelVertexStreamsTests: XCTestCase {
    private let format = MDLVertexFormat(rawValue: MDLVertexAttribute.position.mask | MDLVertexAttribute.normal.mask
                                         | MDLVertexAttribute.texCoord.mask)

    /// Position in its own stream; the other attributes keep their order, shifted past it.
    func testThePositionGetsItsOwnStream() throws {
        let streams = try XCTUnwrap(SceneModelVertexStreams(format))
        XCTAssertEqual(streams.positionStride, MDLVertexAttribute.position.byteSize)
        XCTAssertEqual(streams.positionStride + streams.attributeStride, format.stride)
        XCTAssertEqual(streams.location(of: .position, in: format)?.stream, 0)
        let normal = try XCTUnwrap(streams.location(of: .normal, in: format))
        XCTAssertEqual(normal.stream, 1)
        XCTAssertEqual(normal.offset, try XCTUnwrap(format.offset(of: .normal)) - streams.positionStride)
        XCTAssertNil(streams.location(of: .positionVec4, in: format))
    }

    /// A position-only format, or one without a position, stays one stream.
    func testFormatsWithNothingToSplitStayInterleaved() {
        XCTAssertNil(SceneModelVertexStreams(MDLVertexFormat(rawValue: MDLVertexAttribute.position.mask)))
        XCTAssertNil(SceneModelVertexStreams(MDLVertexFormat(rawValue: MDLVertexAttribute.normal.mask
                                                             | MDLVertexAttribute.texCoord.mask)))
    }

    func testSplittingKeepsEveryByte() throws {
        let streams = try XCTUnwrap(SceneModelVertexStreams(format))
        let bytes = (0..<(format.stride * 3)).map { UInt8(truncatingIfNeeded: $0) }
        var positions = [UInt8](repeating: 0, count: 3 * streams.positionStride)
        var attributes = [UInt8](repeating: 0, count: 3 * streams.attributeStride)
        positions.withUnsafeMutableBytes { p in
            attributes.withUnsafeMutableBytes { a in
                bytes.withUnsafeBytes { streams.split($0, positions: p.baseAddress!, attributes: a.baseAddress!) }
            }
        }
        for vertex in 0..<3 {
            let start = vertex * format.stride
            XCTAssertEqual(Array(positions[(vertex * streams.positionStride)..<((vertex + 1) * streams.positionStride)]),
                           Array(bytes[start..<(start + streams.positionStride)]))
            XCTAssertEqual(Array(attributes[(vertex * streams.attributeStride)..<((vertex + 1) * streams.attributeStride)]),
                           Array(bytes[(start + streams.positionStride)..<(start + format.stride)]))
        }
    }
}
