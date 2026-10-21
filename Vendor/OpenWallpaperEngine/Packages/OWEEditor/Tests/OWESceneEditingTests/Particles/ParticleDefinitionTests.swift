import XCTest
@testable import OWESceneEditing

/// A particle definition as the editor changes it: components added with WE's add values,
/// removed and reordered, fields and flag bits set, and the JSON written as WE writes it, which
/// reads back identically.
final class ParticleDefinitionTests: XCTestCase {
    private var schema: ParticleEditorSchema!

    override func setUpWithError() throws {
        schema = try ParticleFixtures.schema()
    }

    private func rain() throws -> ParticleDefinition {
        try ParticleDefinition(data: Data(ParticleFixtures.rainJSON.utf8))
    }

    func testAComponentIsAddedWithWEsAddValuesANameAndAFreeID() throws {
        var definition = try rain()
        let boids = try XCTUnwrap(schema.component(.operator, name: "boids"))
        let index = try XCTUnwrap(definition.add(boids, pixelUnits: true))
        XCTAssertEqual(index, 2)
        let item = try XCTUnwrap(definition.item(.operator, at: index))
        XCTAssertEqual(item["name"], .string("boids"))
        XCTAssertEqual(item["id"], .number(6), "one more than any component's id")
        XCTAssertEqual(item["neighborthreshold"], .number(50))
        XCTAssertEqual(item["maxspeed"], .number(500))
        XCTAssertEqual(item["flags"], .number(1), "Clamp speed is on when added")

        var perspective = try rain()
        perspective.add(boids, pixelUnits: false)
        XCTAssertEqual(perspective.item(.operator, at: 2)?["neighborthreshold"], .number(0.2), "WE's 3D value")
        XCTAssertEqual(perspective.item(.operator, at: 2)?["separationfactor"], .number(15), "no 3D value: the 2D one")

        let sphere = try XCTUnwrap(schema.component(.emitter, name: "sphererandom"))
        definition.add(sphere, pixelUnits: true)
        let emitter = try XCTUnwrap(definition.item(.emitter, at: 1))
        XCTAssertEqual(emitter["distancemax"], .number(256))
        XCTAssertEqual(emitter["directions"], .string("1 1 0"))
        XCTAssertEqual(emitter["flags"], .number(0))
        XCTAssertEqual(emitter["audioprocessingbounds"], .string("0.8 1.0"))
    }

    func testListsAreRemovedAndReordered() throws {
        var definition = try rain()
        definition.move(.operator, from: 1, to: 0)
        XCTAssertEqual(definition.items(.operator).map { $0["name"]?.stringValue }, ["alphafade", "movement"])
        definition.remove(.initializer, at: 0)
        XCTAssertEqual(definition.items(.initializer).map { $0["name"]?.stringValue }, ["sizerandom"])
        definition.move(.operator, from: 0, to: 5)
        XCTAssertEqual(definition.items(.operator).first?["name"], .string("alphafade"), "an index past the end changes nothing")
        XCTAssertTrue(definition.items(.children).isEmpty, "WE's null list is empty")
        let child = try XCTUnwrap(schema.component(.children))
        definition.add(child, pixelUnits: true)
        XCTAssertEqual(definition.items(.children).first?["type"], .string("static"))
        XCTAssertEqual(definition.items(.children).first?["probability"], .number(1))
    }

    func testControlPointsKeepTheirSlotAsIDAndStopAtEight() throws {
        var definition = try rain()
        let point = try XCTUnwrap(schema.component(.controlpoint))
        for _ in 0..<10 { definition.add(point, pixelUnits: true) }
        XCTAssertEqual(definition.items(.controlpoint).count, 8)
        XCTAssertEqual(definition.items(.controlpoint).map { $0["id"]?.doubleValue }, (0..<8).map(Double.init))
        definition.remove(.controlpoint, at: 0)
        XCTAssertEqual(definition.items(.controlpoint).first?["offset"], .string("100 50 0"))
        XCTAssertEqual(definition.items(.controlpoint).map { $0["id"]?.doubleValue }, (0..<7).map(Double.init))
    }

    func testFlagsAreBitsOfOneField() throws {
        let system = try XCTUnwrap(schema.component(.system))
        let worldspace = try XCTUnwrap(system.field("flags&0x1"))
        let perspective = try XCTUnwrap(system.field("flags&0x4"))
        var root: ParticleDefinition.Item = ["flags": .number(8)]
        ParticleDefinition.set(.bool(true), for: worldspace, in: &root)
        ParticleDefinition.set(.bool(true), for: perspective, in: &root)
        XCTAssertEqual(root["flags"], .number(13))
        ParticleDefinition.set(.bool(false), for: worldspace, in: &root)
        XCTAssertEqual(root["flags"], .number(12))
        XCTAssertEqual(ParticleDefinition.value(of: perspective, in: root), .bool(true))
        XCTAssertEqual(ParticleDefinition.value(of: worldspace, in: root), .bool(false))
        XCTAssertNil(ParticleDefinition.value(of: worldspace, in: [:]), "absent")
        XCTAssertEqual(ParticleDefinition.shownValue(of: worldspace, in: [:], pixelUnits: true), .bool(false), "WE's add value")
    }

    /// A definition built in the editor is written as WE's files are (indented, keys sorted) and
    /// reads back as the same document.
    func testTheWrittenJSONReadsBackIdentically() throws {
        var definition = ParticleDefinition.template
        for (section, name) in [(ParticleEditorSchema.Section.operator, "turbulence"), (.operator, "colorchange"),
                                (.initializer, "rotationrandom"), (.initializer, "colorlist"), (.renderer, "ropetrail"),
                                (.emitter, "boxrandom")] {
            definition.add(try XCTUnwrap(schema.component(section, name: name)), pixelUnits: true)
        }
        definition.add(try XCTUnwrap(schema.component(.controlpoint)), pixelUnits: true)
        definition.updateItem(.operator, at: 0) { $0["gravity"] = .string("0 -98.5 0") }
        definition["maxcount"] = .number(1234)

        let data = try definition.encoded()
        let reread = try ParticleDefinition(data: data)
        XCTAssertEqual(reread, definition)
        XCTAssertEqual(try reread.encoded(), data, "writing again gives the same bytes")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(#""maxcount" : 1234"#), "whole numbers without a fraction")
        XCTAssertTrue(text.contains("materials/particle/halo.json"), "slashes unescaped")
        let keys = try XCTUnwrap(OrderedJSON.parse(data).pairs.map(\.key))
        XCTAssertEqual(keys, keys.sorted(), "keys sorted, as WE writes them")
        XCTAssertEqual(reread.items(.renderer).first?["segments"], .number(4))
        XCTAssertEqual(reread.items(.initializer).last?["colors"], .array([.string("1 1 1")]))
    }

    func testAMaterialsPassIsEdited() throws {
        let json = try XCTUnwrap(SceneJSONValue(any: try JSONSerialization.jsonObject(with: Data(ParticleFixtures.dropMaterialJSON.utf8))))
        var material = try XCTUnwrap(ParticleMaterial(json: json))
        XCTAssertEqual(material.texture, "particle/drop")
        XCTAssertEqual(material.string("blending"), "additive")
        material.texture = "particle/halo"
        material.setString("translucent", for: "blending")
        material.setConstant(.number(2), for: ParticleMaterial.overbrightKey)
        XCTAssertEqual(material.texture, "particle/halo")
        XCTAssertEqual(material.constant(ParticleMaterial.overbrightKey), .number(2))
        XCTAssertEqual(material.string("shader"), "genericparticle", "the rest of the pass is kept")
        material.setConstant(nil, for: ParticleMaterial.overbrightKey)
        guard case .array(let passes)? = material.json["passes"] else { return XCTFail("no passes") }
        XCTAssertNil(passes.first?["constants"], "no constants left")
    }
}
