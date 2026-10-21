import XCTest
@testable import OpenWallpaperEngine

/// `UniformWriter` copies a float member's contiguous runs (an element's components, a matrix
/// column's rows) at once; the bytes are those a store per component at std140's offsets makes.
final class UniformWriterTests: XCTestCase {
    /// The layout rule, one component at a time (what the writer did before it copied runs).
    private func reference(_ components: [Float], member: UniformMember, size: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0xAB, count: size)
        let perElement = UniformWriter.componentsPerElement(member.type)
        let rows = UniformWriter.matrixColumns(member.type).flatMap { member.matrixStride > 0 ? perElement / $0 : nil }
        for index in 0..<min(member.count * perElement, components.count) {
            let element = index / perElement, component = index % perElement
            let base = member.offset + element * member.arrayStride
            let offset = rows.map { base + (component / $0) * member.matrixStride + (component % $0) * 4 } ?? base + component * 4
            guard offset >= 0, offset + 4 <= bytes.count else { continue }
            withUnsafeBytes(of: components[index].bitPattern) { raw in
                for (byte, value) in raw.enumerated() { bytes[offset + byte] = value }
            }
        }
        return bytes
    }

    func testRunsWriteWhatComponentStoresWrite() {
        let members: [(type: String, count: Int, arrayStride: Int, matrixStride: Int)] = [
            ("float", 1, 16, 0), ("float", 7, 16, 0), ("vec2", 3, 16, 0), ("vec3", 5, 16, 0), ("vec4", 6, 16, 0),
            ("mat4", 1, 64, 16), ("mat4", 6, 64, 16), ("mat4x3", 128, 64, 16), ("mat3", 4, 48, 16),
            ("mat3x4", 2, 48, 16), ("mat2", 3, 32, 16), ("mat4", 2, 64, 0),
        ]
        for (type, count, arrayStride, matrixStride) in members {
            for offset in [0, 16, 208] {
                let perElement = UniformWriter.componentsPerElement(type)
                let full = count * arrayStride + offset + 32
                // Full, short of the array, past it, and cut by the end of the buffer.
                for (components, size) in [(count * perElement, full), (count * perElement - 5, full), (count * perElement + 9, full),
                                           (count * perElement, offset + arrayStride * count / 2 + 6)] where components > 0 {
                    let values = (0..<components).map { Float($0) * 1.5 - 7 }
                    let member = UniformMember(name: "u", type: type, offset: offset, count: count, arrayStride: arrayStride,
                                               matrixStride: matrixStride)
                    var bytes = [UInt8](repeating: 0xAB, count: size)
                    UniformWriter.write(values, member: member, into: &bytes)
                    XCTAssertEqual(bytes, reference(values, member: member, size: size),
                                   "\(type)[\(count)] at \(offset), \(components) components into \(size) bytes")
                }
            }
        }
    }
}
