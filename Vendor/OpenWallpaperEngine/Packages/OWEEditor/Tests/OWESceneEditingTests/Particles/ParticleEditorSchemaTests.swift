import XCTest
@testable import OWESceneEditing

/// The particle editor reads WE's editor schema (docs/we-particle-editor-schema.json) into its
/// components and fields: every field gets the control its type names, its key or flag bit, its
/// range, its add value (2D and 3D) and its condition, in WE's panel order.
final class ParticleEditorSchemaTests: XCTestCase {
    private var schema: ParticleEditorSchema!
    private var raw: [String: [String: Any]]!

    override func setUpWithError() throws {
        schema = try ParticleFixtures.schema()
        let data = try Data(contentsOf: ParticleFixtures.schemaURL)
        raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    }

    func testEveryComponentAndFieldOfTheSchemaIsRead() throws {
        let keys = Set(raw.keys).subtracting(["_meta"])
        XCTAssertEqual(Set(schema.components.map(\.id)), keys)
        for component in schema.components {
            let fields = try XCTUnwrap(raw[component.id]?["fields"] as? [String: [String: Any]])
            XCTAssertEqual(Set(component.fields.map(\.id)), Set(fields.keys), "\(component.id): every field maps to a control")
            for field in component.fields {
                let entry = try XCTUnwrap(fields[field.id])
                XCTAssertEqual(field.kind.rawValue, entry["type"] as? String, "\(component.id).\(field.id)")
                XCTAssertEqual(field.label, entry["label"] as? String)
                XCTAssertEqual(field.minimum, (entry["min"] as? NSNumber)?.doubleValue)
                XCTAssertEqual(field.maximum, (entry["max"] as? NSNumber)?.doubleValue)
                if let bit = entry["bit"] as? NSNumber {
                    XCTAssertEqual(field.key, "flags", "\(component.id).\(field.id): a flag is a bit of flags")
                    XCTAssertEqual(field.bit, bit.intValue)
                } else {
                    XCTAssertEqual(field.key, field.id)
                    XCTAssertNil(field.bit)
                }
                XCTAssertNotNil(field.addDefault, "\(component.id).\(field.id) has the value WE writes on add")
            }
        }
    }

    func testFieldsKeepWEsPanelOrder() throws {
        let sphere = try XCTUnwrap(schema.component(.emitter, name: "sphererandom"))
        XCTAssertEqual(Array(sphere.fields.map(\.id).prefix(8)),
                       ["origin", "directions", "sign", "cone", "distancemin", "distancemax", "controlpoint", "rate"])
        let system = try XCTUnwrap(schema.component(.system))
        XCTAssertEqual(system.fields.first?.id, "maxcount")
        XCTAssertEqual(system.fields.last?.id, "sequencemultiplier")
        XCTAssertEqual(schema.components.first?.id, "renderer:sprite", "components in the schema's order too")
    }

    func testFieldsMapToTheirControls() throws {
        let sphere = try XCTUnwrap(schema.component(.emitter, name: "SphereRandom"), "names match without case")
        let distance = try XCTUnwrap(sphere.field("distancemax"))
        XCTAssertEqual(distance.kind, .number)
        XCTAssertEqual(distance.defaultValue(pixelUnits: true), .number(256))
        XCTAssertEqual(distance.defaultValue(pixelUnits: false), .number(1), "WE's 3D add value")
        XCTAssertEqual(sphere.field("controlpoint")?.isInteger, true)
        XCTAssertEqual(sphere.field("rate")?.group, "Count")
        let oneAFrame = try XCTUnwrap(sphere.field("flags&0x2"))
        XCTAssertEqual(oneAFrame.kind, .checkboxbit)
        XCTAssertEqual(oneAFrame.bit, 2)
        let audio = try XCTUnwrap(sphere.field("audioprocessingmode"))
        XCTAssertEqual(audio.kind, .combo)
        XCTAssertEqual(audio.options.map(\.value), [.number(0), .number(1), .number(2), .number(3)])

        let rotation = try XCTUnwrap(schema.component(.initializer, name: "rotationrandom")?.field("max"))
        XCTAssertTrue(rotation.isAngle, "shown in degrees, stored in radians")
        XCTAssertEqual(rotation.kind, .vec3)
        XCTAssertEqual(schema.component(.initializer, name: "colorrandom")?.field("min")?.isNormalized, false, "0–255")
        XCTAssertEqual(schema.component(.operator, name: "colorchange")?.field("startvalue")?.isNormalized, true)
        XCTAssertEqual(schema.component(.initializer, name: "hsvcolorrandom")?.field("huemin")?.kind, .hue)
        let colors = try XCTUnwrap(schema.component(.initializer, name: "colorlist")?.field("colors"))
        XCTAssertEqual(colors.kind, .colorlist)
        XCTAssertEqual(colors.addDefault, .array([.string("1 1 1")]), "a list of one white colour")
        let segments = try XCTUnwrap(schema.component(.renderer, name: "ropetrail")?.field("segments"))
        XCTAssertEqual(segments.kind, .sliderint)
        XCTAssertEqual(segments.minimum, 2)
        XCTAssertEqual(segments.maximum, 16)
        XCTAssertTrue(segments.isInteger)
        XCTAssertEqual(schema.component(.operator, name: "collisionquad")?.field("size")?.components, ["Width", "Depth"])
        XCTAssertEqual(schema.component(.instanceoverride)?.fields.map(\.key), ["alpha", "rate", "speed", "size", "count", "lifetime"])
    }

    func testTheAddDialogLeavesOutWEsLegacyComponents() {
        let operators = schema.components(in: .operator)
        XCTAssertFalse(operators.first { $0.name == "vortex" }?.isAddable ?? true)
        XCTAssertFalse(operators.first { $0.name == "collisionbox" }?.isAddable ?? true)
        XCTAssertTrue(operators.first { $0.name == "vortex_v2" }?.isAddable ?? false)
        XCTAssertEqual(schema.component(.operator, name: "vortex_v2")?.title, "Vortex")
        XCTAssertEqual(schema.component(.initializer, name: "mapsequencearoundcontrolpoint")?.title,
                       "Map sequence around control point", "a raw locale key reads as WE's wording")
        for component in schema.components {
            XCTAssertFalse(component.title.hasPrefix("ui_"), component.id)
            if component.id != "operator:vortex" {
                XCTAssertFalse(component.title.contains("("), component.id + " " + component.title)
            }
        }
    }

    // MARK: Conditions

    private func values(_ item: [String: SceneJSONValue], _ component: ParticleEditorSchema.Component) -> ParticleFieldCondition.Values {
        ParticleDefinition.conditionValues(item, component: component, pixelUnits: true)
    }

    func testEveryConditionOfTheSchemaIsRead() {
        for component in schema.components {
            for field in component.fields {
                guard let text = (raw[component.id]?["fields"] as? [String: [String: Any]])?[field.id]?["condition"] as? String,
                      !text.hasPrefix("none observed") else { continue }
                XCTAssertNotEqual(field.condition, .always, "\(component.id).\(field.id): \(text)")
            }
        }
    }

    func testConditionsShowAndHideFieldsAsWEsPanelDoes() throws {
        let sphere = try XCTUnwrap(schema.component(.emitter, name: "sphererandom"))
        let periodic = try XCTUnwrap(sphere.field("minperiodicduration"))
        XCTAssertFalse(periodic.isVisible(in: values([:], sphere)), "random periodic emission is off by default")
        XCTAssertTrue(periodic.isVisible(in: values(["flags": .number(4)], sphere)))
        let bounds = try XCTUnwrap(sphere.field("audioprocessingbounds"))
        XCTAssertFalse(bounds.isVisible(in: values([:], sphere)))
        XCTAssertTrue(bounds.isVisible(in: values(["audioprocessingmode": .number(3)], sphere)))

        let plane = try XCTUnwrap(schema.component(.operator, name: "collisionplane"))
        let bounce = try XCTUnwrap(plane.field("bouncefactor"))
        XCTAssertTrue(bounce.isVisible(in: values([:], plane)), "bounce is the default behaviour")
        XCTAssertFalse(bounce.isVisible(in: values(["collisionbehavior": .string("Stop")], plane)))

        let sprite = try XCTUnwrap(schema.component(.renderer, name: "sprite"))
        XCTAssertFalse(try XCTUnwrap(sprite.field("axis")).isVisible(in: values([:], sprite)))
        XCTAssertTrue(try XCTUnwrap(sprite.field("axis")).isVisible(in: values(["orientation": .string("fixed")], sprite)))

        let trail = try XCTUnwrap(schema.component(.renderer, name: "ropetrail"))
        XCTAssertFalse(try XCTUnwrap(trail.field("fadealpha")).isVisible(in: values([:], trail)))
        XCTAssertTrue(try XCTUnwrap(trail.field("fadealpha")).isVisible(in: values(["uvscrolling": .bool(true)], trail)))

        let system = try XCTUnwrap(schema.component(.system))
        let multiplier = try XCTUnwrap(system.field("sequencemultiplier"))
        XCTAssertTrue(multiplier.isVisible(in: values([:], system)))
        XCTAssertFalse(multiplier.isVisible(in: values(["animationmode": .string("randomframe")], system)))

        let child = try XCTUnwrap(schema.component(.children))
        let start = try XCTUnwrap(child.field("controlpointstartindex"))
        XCTAssertFalse(start.isVisible(in: values([:], child)))
        XCTAssertTrue(start.isVisible(in: values(["flags": .number(1)], child)))
        XCTAssertTrue(try XCTUnwrap(child.field("maxcount")).isVisible(in: values([:], child)), "WE shows it for a static child")
    }

    func testARemapRangeIsANumberOrAVectorByItsValue() throws {
        let remap = try XCTUnwrap(schema.component(.operator, name: "remapvalue"))
        let range = try XCTUnwrap(remap.field("inputrangemin"))
        XCTAssertTrue(range.isVisible(in: values([:], remap)))
        XCTAssertEqual(range.effectiveKind(in: values(["input": .string("speed")], remap)), .number)
        XCTAssertEqual(range.effectiveKind(in: values(["input": .string("position")], remap)), .vec3)
        let point = try XCTUnwrap(remap.field("inputcontrolpoint0"))
        XCTAssertTrue(point.isVisible(in: values(["input": .string("distancetocontrolpoint")], remap)))
        XCTAssertFalse(point.isVisible(in: values(["input": .string("speed")], remap)))
        let second = try XCTUnwrap(remap.field("inputcontrolpoint1"))
        XCTAssertTrue(second.isVisible(in: values(["input": .string("positionbetweentwocontrolpoints")], remap)))
        XCTAssertFalse(second.isVisible(in: values(["input": .string("controlpoint")], remap)))
        let scale = try XCTUnwrap(remap.field("transforminputscale"))
        XCTAssertFalse(scale.isVisible(in: values([:], remap)), "no transform function by default")
        XCTAssertTrue(scale.isVisible(in: values(["transformfunction": .string("sine")], remap)))
    }

    func testConditionTextReads() {
        XCTAssertEqual(ParticleFieldCondition(expression: "checkFlags(524288)"), .flag(524288))
        XCTAssertEqual(ParticleFieldCondition(expression: "!checkFlags(4)"), .not(.flag(4)))
        XCTAssertEqual(ParticleFieldCondition(expression: "checkBit(findProperty('flags').value, 4)"), .flag(4))
        XCTAssertEqual(ParticleFieldCondition(expression: "checkValue('transformfunction', 'fbmnoise')"),
                       .equals("transformfunction", .string("fbmnoise")))
        XCTAssertEqual(ParticleFieldCondition(expression: "findProperty('orientation').value!='screen'"),
                       .not(.equals("orientation", .string("screen"))))
        XCTAssertEqual(ParticleFieldCondition(expression: "findProperty('audioprocessingmode').value>0"),
                       .greaterThanZero("audioprocessingmode"))
        XCTAssertEqual(ParticleFieldCondition(expression: "checkRemapValueIsScalar('output') (vec3 otherwise)"),
                       .remapScalar("output"))
        XCTAssertEqual(ParticleFieldCondition(expression: nil), .always)
        XCTAssertEqual(ParticleFieldCondition(expression: "none observed: a note"), .always)
    }

    func testOrderedJSONKeepsKeyOrderAndValues() throws {
        let json = try OrderedJSON.parse(Data(#"{"b": 1, "a": [true, null, "x\"y", -2.5e1], "c": {"z": 0, "y": {}}}"#.utf8))
        XCTAssertEqual(json.pairs.map(\.key), ["b", "a", "c"])
        XCTAssertEqual(json["c"]?.pairs.map(\.key), ["z", "y"])
        XCTAssertEqual(json["a"], .array([.bool(true), .null, .string("x\"y"), .number(-25)]))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": 1,}"#.utf8)))
        XCTAssertThrowsError(try OrderedJSON.parse(Data(#"{"a": 1} x"#.utf8)))
    }
}
