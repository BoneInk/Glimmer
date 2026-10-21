import XCTest
@testable import OpenWallpaperEngine

/// Material constants scripts set (`IEffect.setMaterialProperty`, `IMaterial` members) reach the
/// uniforms bound to that scene.json key, the way the loader matches `constantshadervalues`.
final class UniformScriptWriteTests: XCTestCase {
    private typealias Uniform = ShaderConstantResolver.Uniform

    private func member(_ name: String, type: String, offset: Int) -> UniformMember {
        UniformMember(name: name, type: type, offset: offset, count: 1, arrayStride: 16, matrixStride: 0)
    }

    private func floats(_ bytes: [UInt8], at offset: Int, count: Int) -> [Float] {
        (0..<count).map { index in
            bytes[(offset + index * 4)..<(offset + index * 4 + 4)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        }
    }

    func testAScriptWriteLandsOnTheUniformItsKeyNames() {
        let uniforms = [
            Uniform(name: "g_TintColor", glslType: "vec3", annotation: ["material": "color", "default": "1 0 0"]),
            Uniform(name: "g_BlendAlpha", glslType: "float", annotation: ["material": "alpha", "default": 1]),
            Uniform(name: "g_Count", glslType: "float", annotation: ["material": "count", "int": true]),
        ]
        let constants = ShaderConstantResolver.resolve(uniforms: uniforms, material: [:], instance: [:])
        let layout = UniformLayout(size: 48, members: ["g_TintColor": member("g_TintColor", type: "vec3", offset: 0),
                                                       "g_BlendAlpha": member("g_BlendAlpha", type: "float", offset: 16),
                                                       "g_Count": member("g_Count", type: "float", offset: 32)])
        let program = UniformProgram(layout: layout, constants: constants)
        XCTAssertEqual(floats(program.bytes, at: 0, count: 3), [1, 0, 0])

        // Keys match like the loader's: case-insensitively, and by the uniform's bare name.
        program.write([SceneScriptConstantWrite(material: nil, name: "Color", value: [0, 1, 0]),
                       SceneScriptConstantWrite(material: nil, name: "BlendAlpha", value: [0.25]),
                       SceneScriptConstantWrite(material: nil, name: "count", value: [2.6])])
        XCTAssertEqual(floats(program.bytes, at: 0, count: 3), [0, 1, 0])
        XCTAssertEqual(floats(program.bytes, at: 16, count: 1), [0.25])
        XCTAssertEqual(floats(program.bytes, at: 32, count: 1), [3], "an `int` constant is rounded")

        // The last write of a key wins; unknown keys do nothing.
        program.write([SceneScriptConstantWrite(material: nil, name: "color", value: [0.5]),
                       SceneScriptConstantWrite(material: nil, name: "color", value: [0.1, 0.2, 0.3]),
                       SceneScriptConstantWrite(material: nil, name: "nothing", value: [9])])
        XCTAssertEqual(floats(program.bytes, at: 0, count: 3), [0.1, 0.2, 0.3])
    }
}
