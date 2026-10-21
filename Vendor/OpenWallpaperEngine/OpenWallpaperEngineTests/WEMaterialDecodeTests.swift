import XCTest
@testable import OpenWallpaperEngine

/// An image layer's (or particle system's) own material decodes as leniently as WE's loader:
/// vector-string and bool constants and `null` texture slots don't drop the layer.
final class WEMaterialDecodeTests: XCTestCase {
    private func decode(_ json: String, failures: DecodeFailureLog? = nil) throws -> WEMaterial {
        try decodeTolerant(WEMaterial.self, from: Data(json.utf8), failures: failures)
    }

    func testVectorStringAndBoolConstantsDecode() throws {
        let material = try decode("""
        {"passes":[{"shader":"genericimage2","blending":"translucent","textures":["layer"],
          "constantshadervalues":{"color":"1 0.5 0","enabled":true,"off":false,"alpha":0.25,
                                  "speed":"2","bound":{"value":"0.5 0.5","user":"tint"}}}]}
        """)
        let pass = try XCTUnwrap(material.passes?.first)
        XCTAssertEqual(pass.shader, "genericimage2")
        XCTAssertEqual(pass.textures?.first ?? nil, "layer")
        let constants = try XCTUnwrap(pass.constants)
        let color: Double? = constants["color"]?.value
        let enabled: Double? = constants["enabled"]?.value
        let off: Double? = constants["off"]?.value
        let alpha: Double? = constants["alpha"]?.value
        let speed: Double? = constants["speed"]?.value
        let bound: Double? = constants["bound"]?.value
        XCTAssertEqual(color, 1)
        XCTAssertEqual(enabled, 1)
        XCTAssertEqual(off, 0)
        XCTAssertEqual(alpha, 0.25)
        XCTAssertEqual(speed, 2)
        XCTAssertEqual(bound, 0.5)
    }

    func testNullTextureSlotsStayUnsetAndAligned() throws {
        let material = try decode("""
        {"passes":[{"shader":"genericimage2","textures":["layer",null,"masks/mask"]}]}
        """)
        let textures = try XCTUnwrap(material.passes?.first?.textures)
        let expected: [String?] = ["layer", nil, "masks/mask"]
        XCTAssertEqual(textures, expected)
    }

    /// A malformed entry is logged and skipped; the rest of the material, and the layer, stay.
    func testMalformedEntriesAreSkippedNotFatal() throws {
        let failures = DecodeFailureLog()
        let material = try decode("""
        {"passes":[{"shader":"genericimage2","textures":["layer"],"blending":5,
          "constantshadervalues":{"good":1,"bad":[1,2]}}, 7]}
        """, failures: failures)
        let passes = try XCTUnwrap(material.passes)
        let count: Int = passes.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(passes[0].blending)
        let good: Double? = passes[0].constants?["good"]?.value
        XCTAssertEqual(good, 1)
        XCTAssertNil(passes[0].constants?["bad"])
        XCTAssertFalse(failures.messages.isEmpty)
    }

    func testScriptConstantKeepsItsScript() throws {
        let material = try decode("""
        {"passes":[{"shader":"genericparticle","constants":{"ui_editor_properties_refract_amount":{"value":0.3,"script":"x"}}}]}
        """)
        let constant = try XCTUnwrap(material.passes?.first?.constants?["ui_editor_properties_refract_amount"])
        let value: Double? = constant.value
        XCTAssertEqual(value, 0.3)
        XCTAssertEqual(constant.script, "x")
    }
}
