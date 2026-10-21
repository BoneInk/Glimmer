import XCTest
@testable import OpenWallpaperEngine

/// `UserPropertyBindingTable`: every `{"user": …}` of every document is recorded with its path,
/// target and class, and resolving a site follows its property.
final class UserPropertyBindingTableTests: XCTestCase {
    /// One binding of every kind and location scene.json has.
    static let scene = #"""
    {"general": {"bloomstrength": {"user": "glow", "value": 2}, "clearcolor": "0 0 0"},
     "objects": [
       {"id": 1, "image": "models/a.json", "origin": {"user": "place", "value": "10 20 0"},
        "alpha": {"user": "fade", "value": 1}, "size": {"user": "big", "value": "64 64"},
        "visible": {"user": {"name": "mode", "condition": "2"}, "value": false},
        "instance": {"constantshadervalues": {"tint": {"user": "tint", "value": "1 1 1"}}},
        "effects": [{"file": "effects/e/effect.json", "visible": {"user": "fx", "value": true},
                     "passes": [{"combos": {"MODE": {"user": "variant", "value": 1}},
                                 "constantshadervalues": {"speed": {"user": "speed", "value": 1},
                                                          "wave": {"script": "export function update(v) { return v; }",
                                                                   "scriptproperties": {"amount": {"user": "amount", "value": 3}},
                                                                   "value": 0.5}}}]}],
        "animationlayers": [{"rate": {"user": "rate", "value": 1}, "animation": 1}]},
       {"id": 2, "text": {"user": "caption", "value": "hi"}, "color": {"user": "ink", "value": "1 1 1"},
        "pointsize": {"user": "points", "value": 32}},
       {"particle": "particles/p.json",
        "instanceoverride": {"colorn": {"user": "tint", "value": "1 0 0"}, "count": {"user": "amount", "value": 1}}},
       {"id": 4, "light": "point", "origin": {"user": "place", "value": "0 0 0"}},
       {"id": 5, "image": "models/b.json", "unheardof": {"user": "odd", "value": 7}}
     ]}
    """#

    private func table(_ json: String = scene) throws -> (UserPropertyBindingTable, SceneJSON) {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Data(json.utf8))
        let table = UserPropertyBindingTable()
        table.record(.scene, json: document)
        return (table, document)
    }

    private func binding(_ table: UserPropertyBindingTable, _ path: String) throws -> UserPropertyBinding {
        try XCTUnwrap(table.all.first { $0.site.path.description == path }, "no binding at \(path)")
    }

    func testEveryKindIsRecordedWithItsTargetAndClass() throws {
        let (table, _) = try table()
        let expected: [(String, UserPropertyBindingTarget, UserPropertyBindingDependency, UserPropertyBindingOwner)] = [
            ("general/bloomstrength", .general("bloomstrength"), .structural, .scene),
            ("objects/0/origin", .objectField(.origin), .object, .object(1)),
            ("objects/0/alpha", .objectField(.alpha), .object, .object(1)),
            ("objects/0/size", .objectField(.size), .structural, .object(1)),
            ("objects/0/visible", .objectVisible, .object, .object(1)),
            ("objects/0/instance/constantshadervalues/tint", .shaderConstant(effect: nil, pass: 0, key: "tint"), .uniform, .object(1)),
            ("objects/0/effects/0/visible", .effectVisible(effect: 0), .object, .object(1)),
            ("objects/0/effects/0/passes/0/combos/MODE", .combo(effect: 0, pass: 0, key: "MODE"), .structural, .object(1)),
            ("objects/0/effects/0/passes/0/constantshadervalues/speed",
             .shaderConstant(effect: 0, pass: 0, key: "speed"), .uniform, .object(1)),
            ("objects/0/effects/0/passes/0/constantshadervalues/wave/scriptproperties/amount",
             .scriptValue("objects/0/effects/0/passes/0/constantshadervalues/wave/scriptproperties/amount"), .object, .object(1)),
            ("objects/0/animationlayers/0/rate", .animationLayer(layer: 0, field: "rate"), .object, .object(1)),
            ("objects/1/text", .text, .structural, .object(2)),
            ("objects/1/color", .objectField(.color), .object, .object(2)),
            ("objects/1/pointsize", .objectField(.pointsize), .structural, .object(2)),
            ("objects/2/instanceoverride/colorn", .instanceOverride("colorn"), .object, .object(2)),
            ("objects/2/instanceoverride/count", .instanceOverride("count"), .structural, .object(2)),
            ("objects/3/origin", .objectField(.origin), .structural, .object(4)),
            ("objects/4/unheardof", .other("objects/4/unheardof"), .structural, .object(5)),
        ]
        for (path, target, dependency, owner) in expected {
            let found = try binding(table, path)
            XCTAssertEqual(found.target, target, path)
            XCTAssertEqual(found.dependency, dependency, path)
            XCTAssertEqual(found.owner, owner, path)
        }
        XCTAssertEqual(table.all.count, expected.count, "every occurrence, nothing else")
        XCTAssertEqual(try binding(table, "objects/0/visible").condition, "2")
    }

    func testAssetDocumentsAreRecordedAndOwnedByTheObjectsThatReadThem() throws {
        let material = #"""
        {"passes": [{"shader": "genericimage2", "combos": {"LIGHTING": {"user": "lit", "value": 0}},
                     "constantshadervalues": {"tint": {"user": "tint", "value": "1 1 1"}, "glow": 0.5},
                     "usershadervalues": {"schemecolor": "glow"}}]}
        """#
        let table = UserPropertyBindingTable()
        let values = ["lit": "1", "tint": "0 0.5 1"]
        let resolved = table.building(.object(7)) {
            table.resolvedData(Data(material.utf8), path: "materials/m.json", properties: { values[$0] })
        }
        _ = table.building(.object(9)) {
            table.resolvedData(Data(material.utf8), path: "materials/m.json", properties: { values[$0] })
        }
        let combo = try binding(table, "passes/0/combos/LIGHTING")
        XCTAssertEqual(combo.target, .combo(effect: nil, pass: 0, key: "LIGHTING"))
        XCTAssertEqual(combo.dependency, .structural)
        XCTAssertEqual(table.owners(of: combo), [.object(7), .object(9)])
        XCTAssertEqual(try binding(table, "passes/0/constantshadervalues/tint").dependency, .uniform)
        let scheme = try binding(table, "passes/0/usershadervalues/schemecolor")
        XCTAssertEqual(scheme.target, .userShaderValue(key: "glow"))
        XCTAssertEqual(scheme.defaultValue, .number(0.5))

        let decoded = try JSONDecoder().decode(SceneJSON.self, from: resolved)
        guard case .object(let root) = decoded, case .array(let passes)? = root["passes"],
              case .object(let pass) = passes[0], case .object(let combos)? = pass["combos"],
              case .object(let constants)? = pass["constantshadervalues"],
              case .object(let tint)? = constants["tint"] else { return XCTFail("shape: \(decoded)") }
        XCTAssertEqual(combos["LIGHTING"], .number(1), "a structural site is the bare value its parser reads")
        XCTAssertEqual(tint["value"], .string("0 0.5 1"))
        XCTAssertEqual(tint["user"], .string("tint"), "a live site keeps its binding")
        let decodedMaterial = try JSONDecoder().decode(MaterialDocument.self, from: resolved)
        XCTAssertEqual(decodedMaterial.passes.first?.combos["LIGHTING"], 1, "no parser drops a bound combo")
        XCTAssertEqual(table.changes(for: ["lit"]), [.object(7): .structural, .object(9): .structural])
        XCTAssertEqual(table.changes(for: ["tint"]), [.object(7): .uniform, .object(9): .uniform])
    }

    func testFilesThatBindNothingPassThrough() {
        let table = UserPropertyBindingTable()
        let plain = Data(#"{"passes": [{"shader": "x", "constantshadervalues": {"a": 1}}]}"#.utf8)
        XCTAssertEqual(table.resolvedData(plain, path: "materials/plain.json", properties: { _ in "1" }), plain)
        let shader = Data("uniform float g_User; // {\"user\": 1}".utf8)
        XCTAssertEqual(table.resolvedData(shader, path: "shaders/a.frag", properties: { _ in "1" }), shader)
        XCTAssertTrue(table.all.isEmpty)
    }

    func testValueConversion() {
        typealias C = UserPropertyValueConversion
        XCTAssertEqual(C.siteValue("2", condition: "2.0", default: .bool(false)), .bool(true))
        XCTAssertEqual(C.siteValue("Two", condition: "two", default: .bool(false)), .bool(true), "a combo option, loosely")
        XCTAssertEqual(C.siteValue("Two", condition: "three", default: .bool(true)), .bool(false))
        XCTAssertEqual(C.siteValue("2", condition: "2", default: .number(0)), .number(1), "in the authored type")
        XCTAssertEqual(C.siteValue("false", condition: nil, default: .bool(true)), .bool(false))
        XCTAssertEqual(C.siteValue("0.25", condition: nil, default: .number(1)), .number(0.25))
        XCTAssertEqual(C.siteValue("true", condition: nil, default: .number(0)), .number(1))
        XCTAssertEqual(C.siteValue("option", condition: nil, default: .number(3)), .number(3), "no numeric meaning")
        XCTAssertEqual(C.siteValue("0.1 0.2 0.3", condition: nil, default: .string("1 1 1")), .string("0.1 0.2 0.3"))
        XCTAssertEqual(C.siteValue("Hello", condition: nil, default: .string("hi")), .string("Hello"))
        XCTAssertEqual(C.siteValue("red", condition: nil, default: .string("1 1 1")), .string("1 1 1"))
        XCTAssertEqual(C.scriptValue("1", type: "bool", declared: .bool(false)), .bool(true))
        XCTAssertEqual(C.scriptValue("0.5", type: "slider", declared: .number(0)), .number(0.5))
        XCTAssertEqual(C.scriptValue("1 0 0", type: "color", declared: .string("0 0 0")), .string("1 0 0"))
        XCTAssertEqual(C.scriptValue("2", type: "combo", declared: .number(1)), .number(2))
    }

    private struct Properties: SceneValueContext {
        var values: [String: String] = [:]
        func userProperty(_ name: String) -> String? { values[name] }
    }

    /// Particle overrides (`colorn` among them), a timeline's base and a script's properties follow
    /// their property, live as a fresh load does.
    func testParticleTimelineAndScriptSitesFollowTheirProperties() throws {
        let json = #"""
        {"camera": {"center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"}, "general": {},
         "objects": [
          {"id": 3, "particle": "particles/p.json",
           "instanceoverride": {"colorn": {"user": "sparkcolor", "value": "1 0 0"}, "count": {"user": "sparks", "value": 1}}},
          {"id": 4, "image": "models/a.json",
           "alpha": {"user": "fade", "value": 1, "animation": {"c0": [], "options": {"fps": 30, "length": 60, "mode": "loop"}}}},
          {"id": 5, "image": "models/a.json",
           "origin": {"script": "export function update(v) { return v; }",
                      "scriptproperties": {"speed": {"user": "speed", "value": 2}}, "value": "0 0 0"}}
        ]}
        """#
        let (table, document) = try self.table(json)
        let values = ["sparkcolor": "0 0 1", "sparks": "3", "fade": "0.5", "speed": "5"]
        let scene = try UserPropertyBindingTable.decode(
            WEScene.self, from: table.resolvedDocument(document, document: .scene, properties: { values[$0] }))

        let fresh = SceneParticleOverrides(scene.objects[0].instanceoverride, in: Properties())
        XCTAssertEqual(fresh.tint, SIMD3(0, 0, 1), "colorn follows its property")
        XCTAssertEqual(fresh.count, 3)
        let authored = try UserPropertyBindingTable.decode(WEScene.self, from: document).objects[0].instanceoverride
        let live = SceneParticleOverrides(authored, in: Properties(values: values))
        XCTAssertEqual(live.tint, fresh.tint, "the live overrides draw what a fresh load does")
        XCTAssertEqual(try binding(table, "objects/0/instanceoverride/colorn").dependency, .object)
        XCTAssertEqual(try binding(table, "objects/0/instanceoverride/count").dependency, .structural)

        let timeline = try binding(table, "objects/1/alpha")
        XCTAssertEqual(timeline.dependency, .object)
        XCTAssertFalse(timeline.collapses, "the timeline keeps running over the bound value")
        XCTAssertEqual(scene.objects[1].values[.alpha]?.literalDouble, 0.5)
        XCTAssertNotNil(scene.objects[1].values[.alpha]?.animation)

        let script = try binding(table, "objects/2/origin/scriptproperties/speed")
        XCTAssertEqual(script.dependency, .object)
        XCTAssertEqual(script.owner, .object(5))
        guard case .object(let root) = table.resolvedDocument(document, document: .scene, properties: { values[$0] }),
              case .array(let objects)? = root["objects"], case .object(let object) = objects[2],
              case .object(let origin)? = object["origin"], case .object(let properties)? = origin["scriptproperties"],
              case .object(let speed)? = properties["speed"] else { return XCTFail("shape") }
        XCTAssertEqual(speed["value"], .number(5), "the script reads its property's value")
    }

    /// Scripts read the properties through the same conversion as the bindings.
    func testScriptsReadTheConvertedValues() throws {
        let project = try JSONDecoder().decode(SceneJSON.self, from: Data(#"""
            {"general": {"properties": {
              "on": {"type": "bool", "value": false}, "level": {"type": "slider", "value": 0},
              "ink": {"type": "color", "value": "0 0 0"}, "mode": {"type": "combo", "value": 1},
              "caption": {"type": "textinput", "value": ""}}}}
            """#.utf8))
        var properties = SceneScriptUserProperties(project: project)
        let stored = ["on": "true", "level": "0.25", "ink": "1 0.5 0", "mode": "2", "caption": "Hello"]
        properties.setStoredValues(stored)
        XCTAssertEqual(properties.value(of: "on"), .bool(true))
        XCTAssertEqual(properties.value(of: "level"), .number(0.25))
        XCTAssertEqual(properties.value(of: "ink"), .string("1 0.5 0"))
        XCTAssertEqual(properties.value(of: "mode"), .number(2))
        XCTAssertEqual(properties.value(of: "caption"), .string("Hello"))
        let payload = properties.payload(only: ["ink"])
        XCTAssertEqual((payload["ink"] as? [String: Any])?["type"] as? String, "color", "the runtime makes it a Vec3")
    }

    /// For any recorded binding, resolving with another value of its property changes what the
    /// table hands the parsers.
    func testEveryRecordedBindingFollowsItsProperty() throws {
        let (table, document) = try table()
        XCTAssertFalse(table.all.isEmpty)
        for binding in table.all {
            let fresh = UserPropertyBindingTable.value(of: binding, properties: { _ in nil })
            XCTAssertEqual(fresh, binding.defaultValue ?? .null, "no value: the authored one (\(binding.site))")
            let other = Self.differentValue(for: binding)
            let resolved = table.resolve(binding.site, properties: { $0 == binding.name ? other : nil })
            XCTAssertNotEqual(resolved, binding.defaultValue, "\(binding.site) ignores its property")
            let before = table.resolvedDocument(document, document: .scene, properties: { _ in nil })
            let after = table.resolvedDocument(document, document: .scene, properties: { $0 == binding.name ? other : nil })
            XCTAssertNotEqual(before, after, "\(binding.site) doesn't reach the parsers")
        }
    }

    /// A property value unlike `binding`'s authored one, in the text form the store keeps.
    static func differentValue(for binding: UserPropertyBinding) -> String {
        if let condition = binding.condition {
            let fallback = binding.defaultValue == .bool(true)
            return fallback ? condition + "x" : condition
        }
        switch binding.defaultValue {
        case .bool(let flag)?: return flag ? "false" : "true"
        case .number(let number)?: return String(number + 1)
        case .string(let text)?:
            guard let value = ShaderValue(string: text) else { return text + "!" }
            return value.components.map { String($0 + 0.5) }.joined(separator: " ")
        default: return "7"
        }
    }
}
