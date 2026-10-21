import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Bound buffers are at least as long as the MSL type the kernel or shader declares there
/// (`MTL_DEBUG_LAYER` reports anything shorter).
final class MetalBufferSizeTests: XCTestCase {
    /// A `WEUniforms` block whose packed size (132) isn't a multiple of 16: a `vec4` and a `mat4`
    /// put the MSL struct at 16-byte alignment, so Metal expects 144 bytes.
    func testUniformBlockLengthCoversTheMetalStruct() throws {
        let json = """
        {"types": {"_10": {"name": "WEUniforms", "members": [
            {"name": "g_Color", "type": "vec4", "offset": 0},
            {"name": "g_ModelViewProjectionMatrix", "type": "mat4", "offset": 16, "matrix_stride": 16},
            {"name": "g_Alpha", "type": "float", "offset": 80},
            {"name": "g_Points", "type": "vec2", "offset": 88, "array": [5], "array_stride": 8},
            {"name": "g_Strength", "type": "float", "offset": 128}]}},
         "ubos": [{"type": "_10", "name": "", "block_size": 132, "set": 0, "binding": 0}]}
        """
        let layout = try XCTUnwrap(ShaderVariantTranslator.uniformLayout(from: Data(json.utf8)))
        XCTAssertGreaterThanOrEqual(layout.size, 144)
        XCTAssertEqual(layout.size % 16, 0)
        // Every renderer's uniform bytes, and so the uploaded length, are the layout's size.
        let uniforms = ImageMaterialUniforms(layout: layout, constants: .init(staticValues: [:], dynamic: []), liveFactors: [:])
        XCTAssertGreaterThanOrEqual(uniforms.size, 144)
    }

    func testMetalAlignmentOfReflectedTypes() {
        XCTAssertEqual(ShaderVariantTranslator.metalAlignment(ofReflectedType: "float"), 4)
        XCTAssertEqual(ShaderVariantTranslator.metalAlignment(ofReflectedType: "vec2"), 8)
        XCTAssertEqual(ShaderVariantTranslator.metalAlignment(ofReflectedType: "ivec3"), 16)
        XCTAssertEqual(ShaderVariantTranslator.metalAlignment(ofReflectedType: "mat4"), 16)
        XCTAssertEqual(ShaderVariantTranslator.metalAlignment(ofReflectedType: "mat3x2"), 8)
    }

    /// An unlinked system binds a zeroed buffer holding one `LinkedPoints`, not its control words.
    func testUnlinkedSystemsBindAFullLinkedPointsBuffer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let simulator = try ParticleGPUSimulator(device: device)
        let buffer = simulator.unlinkedPoints
        XCTAssertGreaterThanOrEqual(buffer.length, MemoryLayout<ParticleGPULinkedPoints>.stride)
        XCTAssertGreaterThan(buffer.length, ParticleGPUSystem.Control.words * 4)
        let bytes = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
        XCTAssertTrue(bytes.allSatisfy { $0 == 0 })
    }
}
