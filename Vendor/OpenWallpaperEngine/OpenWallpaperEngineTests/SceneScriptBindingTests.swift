import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// Property binding (docs/scenescript-plan.md WP8, §1.9 P2/P3; test-risks S6, S7, S8, S25, S26):
/// every kind of binding site, WE's converter for each property type, and value chaining.
final class SceneScriptBindingTests: XCTestCase {
    private static let image = SceneScriptObjectDescription.make(
        .image, id: 1, name: "Image",
        values: [.alpha: [0], .origin: [10, 20, 30], .scale: [1, 1, 1], .angles: [0, 0, 0], .color: [1, 1, 1],
                 .parallaxDepth: [1, 1]],
        effects: [
            .init(name: "tint", visible: true, materials: [.init(constants: [.init(name: "multiply", value: [1]),
                                                                              .init(name: "color", value: [1, 0, 0])])]),
            .init(name: "cover", visible: false, materials: [.init(constants: [])]),
        ])
    private static let text = SceneScriptObjectDescription.make(.text, id: 2, name: "Clock", values: [.pointsize: [32]],
                                                                strings: [.text: "<Clock>"])
    private static let sparks = SceneScriptObjectDescription.make(.particle, id: 3, name: "Sparks")

    private func fixture() throws -> SceneScriptBindingFixture {
        try SceneScriptBindingFixture(objects: [Self.image, Self.text, Self.sparks])
    }

    /// A scene.json with one object's field bound to `script` (JSON-escaped here).
    private func scene(object: Int, field: String, value: String, script: String, extra: String = "") -> String {
        let name = [1: "Image", 2: "Clock", 3: "Sparks"][object] ?? "Image"
        let bound = "{\"script\": \(Self.literal(script)), \"value\": \(value)\(extra)}"
        let path = field.split(separator: ".").map(String.init)
        var node = bound
        for key in path.dropFirst().reversed() { node = "{\"\(key)\": \(node)}" }
        return "{\"objects\": [{\"id\": \(object), \"name\": \"\(name)\", \"\(path[0])\": \(node)}]}"
    }

    static func literal(_ text: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [text], options: [])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func number(_ value: JSValue?) -> Double? { value?.isNumber == true ? value?.toDouble() : nil }

    private func vector(_ value: JSValue?) -> [Double] {
        guard let value, value.isObject else { return [] }
        return ["x", "y", "z", "w"].compactMap { key in
            let component = value.forProperty(key)
            return component?.isNumber == true ? component?.toDouble() : nil
        }
    }

    // MARK: - Numbers (alpha)

    func testAccumulatorChainsTheReturnedValue() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load(scene(object: 1, field: "alpha", value: "0", script: "export function update(value) { return value + 0.25; }"))
        f.frames(3)
        XCTAssertEqual(f.table(0, .alpha), [0.75])
        XCTAssertEqual(number(f.value("Image", "alpha")), 0.75)
        XCTAssertTrue(f.errors.isEmpty, "\(f.errors)")
    }

    func testInitsReturnSeedsTheFirstUpdate() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "alpha", value: "0", script: """
            export function init(value) { return 0.5; }
            export function update(value) { shared.first = shared.first === undefined ? value : shared.first; return value + 0.25; }
            """))
        XCTAssertEqual(f.table(0, .alpha), [0.5], "init's return is applied at load")
        f.frames(1)
        XCTAssertEqual(f.evaluate("shared.first")?.toDouble(), 0.5)
        XCTAssertEqual(f.table(0, .alpha), [0.75])
    }

    func testRejectedReturnsKeepTheValueAndNaNIsWritten() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "alpha", value: "0", script: """
            let calls = 0;
            export function update(value) {
                calls++;
                if (calls === 1) return undefined;
                if (calls === 2) return 'abc';
                if (calls === 3) return true;
                if (calls === 4) return null;
                if (calls === 5) return { x: 1 };
                return NaN;
            }
            """))
        f.frames(5)
        XCTAssertEqual(f.table(0, .alpha), [0])
        f.frames(1)
        XCTAssertTrue(f.table(0, .alpha)[0].isNaN, "P3: NaN passes WE's number check")
    }

    func testDirectWritesByOtherScriptsReachTheArgument() throws {
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Image",
              "alpha": {"script": "export function update(value) { shared.seen = value; return value; }", "value": 0},
              "origin": {"script": "export function update(value) { thisLayer.alpha = 0.5; }", "value": "10 20 30"}}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.evaluate("shared.seen")?.toDouble(), 0.5, "P2: the argument is the property's live value")
    }

    // MARK: - Vectors (origin, scale, angles, color, parallaxDepth)

    func testVectorReturnsFollowWEsConverter() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load(scene(object: 1, field: "origin", value: "\"10 20 30\"", script: """
            let calls = 0;
            export function update(value) {
                calls++;
                if (calls === 1) return 2;
                if (calls === 2) return { x: 1, y: 2, z: 3 };
                if (calls === 3) return '4 5 6';
                if (calls === 4) return new Vec2(7, 8);
                if (calls === 5) return { x: 1, y: 'a', z: 3 };
                return new Vec3(9, 8, 7);
            }
            """))
        f.frames(1)
        XCTAssertEqual(f.table(0, .origin), [2, 2, 2], "a number is broadcast")
        f.frames(1)
        XCTAssertEqual(f.table(0, .origin), [1, 2, 3], "any object with numeric x, y, z")
        f.frames(3)
        XCTAssertEqual(f.table(0, .origin), [1, 2, 3], "text, a Vec2 and a non-numeric component are rejected")
        f.frames(1)
        XCTAssertEqual(f.table(0, .origin), [9, 8, 7])
    }

    func testTheArgumentIsAFreshVectorEveryCall() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Image",
              "origin": {"script": "export function update(value) { value.x += 1; }", "value": "10 20 30"},
              "scale": {"script": "const k = new Vec3(1, 1, 1); export function update(value) { k.x += 1; const out = k; k.y = 100; return out.x < 3 ? out : undefined; } export function init() { engine.setTimeout(function () { k.z = 50; }, 20); }", "value": "1 1 1"}}]}
            """)
        f.frames(4)
        XCTAssertEqual(f.table(0, .origin), [10, 20, 30], "S7: changing the argument without returning it changes nothing")
        let scale = f.table(0, .scale)
        XCTAssertEqual(scale[0], 2)
        XCTAssertEqual(scale[1], 100, "the returned object's state at return time")
        XCTAssertEqual(scale[2], 1, "later changes to a returned object don't reach the property")
    }

    func testAnglesAreDegreesAtTheAPI() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "angles", value: "\"0 0 0\"", script: """
            export function update(value) { shared.z = value.z; value.z += 90; return value; }
            """))
        f.frames(2)
        XCTAssertEqual(f.evaluate("shared.z")?.toDouble(), 90, "the second call gets the degrees the first returned")
        XCTAssertEqual(Double(f.table(0, .angles)[2]), Double.pi, accuracy: 1e-5)
    }

    func testColorAndParallaxDepthAndScale() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Image",
              "color": {"script": "export function update(value) { return new Vec3(value.x * 0.5, 0.25, 1); }", "value": "1 1 1"},
              "parallaxDepth": {"script": "export function update(value) { return 0.5; }", "value": "1 1"},
              "scale": {"script": "export function update(value) { return value.multiply(2); }", "value": "1 1 1"}}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.table(0, .color), [0.25, 0.25, 1])
        XCTAssertEqual(f.table(0, .parallaxDepth), [0.5, 0.5])
        XCTAssertEqual(f.table(0, .scale), [4, 4, 4])
    }

    // MARK: - Flags (visible)

    func testFlagsAcceptOnlyBooleans() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "visible", value: "true", script: """
            let calls = 0;
            export function update(value) { calls++; return calls === 1 ? 0 : (calls === 2 ? 'false' : false); }
            """))
        f.frames(2)
        XCTAssertEqual(f.table(0, .visible), [1], "IsBoolean only: 0 and 'false' are rejected")
        f.frames(1)
        XCTAssertEqual(f.table(0, .visible), [0])
    }

    func testALayerHiddenInInitKeepsUpdatingAndShowsAgain() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "visible", value: "true", script: """
            let frames = 0;
            export function init(value) { return false; }
            export function update(value) { frames++; return frames >= 30 ? true : value; }
            """))
        XCTAssertEqual(f.table(0, .visible), [0])
        f.frames(29)
        XCTAssertEqual(f.table(0, .visible), [0], "S26/P6: update runs on the hidden layer")
        f.frames(1)
        XCTAssertEqual(f.table(0, .visible), [1])
    }

    // MARK: - Strings (text)

    func testTextNeverBecomesUndefined() throws {
        let f = try fixture()
        try f.load(scene(object: 2, field: "text", value: "\"<Clock>\"", script: """
            let calls = 0;
            export function update(value) {
                calls++;
                if (calls === 1) return undefined;
                if (calls === 2) return null;
                if (calls === 3) return 42;
                if (calls === 4) return { toString() { return 'object'; } };
                return value + '!';
            }
            """))
        let layer = "thisScene.getLayer('Clock').text"
        f.frames(2)
        XCTAssertEqual(f.evaluate(layer)?.toString(), "<Clock>")
        f.frames(1)
        XCTAssertEqual(f.evaluate(layer)?.toString(), "42", "ToString: a number becomes its text")
        f.frames(1)
        XCTAssertEqual(f.evaluate(layer)?.toString(), "object")
        f.frames(1)
        XCTAssertEqual(f.evaluate(layer)?.toString(), "object!")
        let strings = f.objectHost.takeCommands().compactMap { command -> String? in
            if case .setString(_, .text, let value) = command { return value }
            return nil
        }
        XCTAssertFalse(strings.contains("undefined"))
        XCTAssertEqual(strings.last, "object!")
    }

    func testAThrowingToStringKeepsTheText() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load(scene(object: 2, field: "text", value: "\"<Clock>\"", script: """
            export function update(value) { return { toString() { throw new Error('no'); } }; }
            """))
        f.frames(2)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Clock').text")?.toString(), "<Clock>")
        XCTAssertEqual(f.errors.first?.callback, "<value>")
    }

    func testPointsizeIsANumber() throws {
        let f = try fixture()
        try f.load(scene(object: 2, field: "pointsize", value: "32", script: "export function update(value) { return value * 2; }"))
        f.frames(1)
        XCTAssertEqual(f.table(1, .pointsize), [64])
    }

    // MARK: - Fields outside the object model (brightness)

    func testAFieldTheObjectModelLacksChainsThroughTheScript() throws {
        let f = try fixture()
        try f.load(scene(object: 1, field: "brightness", value: "1", script: "export function update(value) { return value * 2; }"))
        f.frames(3)
        XCTAssertEqual(number(f.value("Image", "brightness")), 8)
    }

    // MARK: - Effects and materials (S25)

    func testEffectVisibleBindsThisObjectToTheEffect() throws {
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Image", "effects": [
              {"visible": true},
              {"visible": {"script": "export function mediaThumbnailChanged(event) { thisObject.visible = event.hasThumbnail; } export function update(value) { shared.cover = value; return value; }", "value": false}}]}]}
            """)
        f.frames(1)
        XCTAssertEqual(f.evaluate("shared.cover")?.toBool(), false)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Image').getEffect(1).visible")?.toBool(), false)
        f.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true }])")
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Image').getEffect(1).visible")?.toBool(), true,
                       "an effect hidden at load is shown by the media event")
        XCTAssertEqual(f.evaluate("shared.cover")?.toBool(), true, "and the next update sees it")
    }

    func testMaterialConstantsBindThisObjectToTheMaterial() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Image", "effects": [{"passes": [{"constantshadervalues": {
              "multiply": {"script": "export function update(value) { shared.isMaterial = thisObject.getMaterialProperty('multiply') === value; return value + 1; }", "value": 1},
              "color": {"script": "export function update(value) { return new Vec3(0, value.x, 1); }", "value": "1 0 0"}}}]}]}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.evaluate("shared.isMaterial")?.toBool(), true)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Image').getEffect(0).getMaterial(0).multiply")?.toDouble(), 3)
        XCTAssertEqual(vector(f.evaluate("thisScene.getLayer('Image').getEffect(0).getMaterial(0).color")), [0, 0, 1])
        let writes = f.objectHost.takeCommands().compactMap { command -> [Float]? in
            guard case .setMaterialProperty(let slot, let effect, let material, let name, let value) = command,
                  slot == 0, effect == 0, material == 0, name == "multiply" else { return nil }
            return value
        }
        XCTAssertEqual(writes, [[2], [3]], "each applied return reaches the renderer")
    }

    // MARK: - Particles and the scene

    func testInstanceOverrides() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 3, "name": "Sparks", "instanceoverride": {
              "rate": {"script": "export function update(value) { return value * 2; }", "value": 1.5},
              "alpha": {"script": "export function update(value) { return 0.25; }", "value": 1},
              "colorn": {"script": "let calls = 0; export function update(value) { calls++; return calls === 1 ? new Vec3(1, 0.5, 0) : 0.5; }", "value": "1 1 1"},
              "lifetime": {"script": "export function update(value) { return 'long'; }", "value": 2}}}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.table(2, .instanceRate), [4], "1 (the table's multiplier) × 2 × 2: the live value chains")
        XCTAssertEqual(f.table(2, .instanceAlpha), [0.25])
        XCTAssertEqual(f.table(2, .instanceColorn), [0.5], "colorn is a Number (lib.sceneScript.d.ts): a Vec3 is rejected")
        XCTAssertEqual(f.table(2, .instanceLifetime), [1])
    }

    func testGeneralFieldsBindToTheScene() throws {
        let f = try SceneScriptBindingFixture(objects: [Self.image], settings: [.bloomstrength: [2]])
        try f.load("""
            {"general": {
              "bloomstrength": {"script": "export function update(value) { shared.scene = thisObject === thisScene; return value / 2; }", "value": 2},
              "camerashake": {"script": "export function update(value) { return !value; }", "value": false}},
             "objects": [{"id": 1, "name": "Image"}]}
            """)
        f.frames(1)
        XCTAssertEqual(f.evaluate("shared.scene")?.toBool(), true, "P9: thisObject is the scene")
        XCTAssertEqual(f.evaluate("thisScene.bloomstrength")?.toDouble(), 1)
        XCTAssertEqual(f.evaluate("thisScene.camerashake")?.toBool(), true)
    }

    /// LF2: the Knight (2515150033) binds scripts to its legacy light's `intensity` and `origin`.
    /// `intensity` isn't an `ILayer` member (lib.sceneScript.d.ts has no light interface), but the
    /// script sets it every frame and gets the value it set as its argument.
    func testALightFieldBindsWithoutBeingAMember() throws {
        _ = try Fixtures.assets()
        let lamp = SceneScriptObjectDescription.make(.light, id: 29, name: "Lamp",
                                                     values: [.intensity: [1], .origin: [2124, 536, 588]])
        let f = try SceneScriptBindingFixture(objects: [lamp])
        try f.load("""
            {"objects": [{"id": 29, "name": "Lamp", "light": "point",
              "intensity": {"script": "export function update(value) { shared.seen = (shared.seen || []).concat([value]); return value + 0.5; }", "value": 1},
              "origin": {"script": "export function update(value) { value.z = 700; return value; }", "value": "2124 536 588"}}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.table(0, .intensity), [2], "the bound script sets it every frame")
        XCTAssertEqual(f.table(0, .origin), [2124, 536, 700], "origin.z reaches the table")
        XCTAssertEqual(f.evaluate("shared.seen.join(',')")?.toString(), "1,1.5", "the argument is the live value")
        XCTAssertEqual(f.evaluate("'intensity' in thisScene.getLayer('Lamp')")?.toBool(), false, "not a member")
        XCTAssertTrue(f.errors.isEmpty, "\(f.errors)")
    }

    /// B2: 2350874185 binds a script to `general.bloomhdrstrength`. `IScene` doesn't declare the
    /// `bloomhdr*` fields, but a bound script sets them.
    func testHDRBloomFieldsBindToTheSceneWithoutBeingMembers() throws {
        _ = try Fixtures.assets()
        let f = try SceneScriptBindingFixture(objects: [Self.image], settings: [.bloomhdrstrength: [2]])
        try f.load("""
            {"general": {
              "bloomhdrstrength": {"script": "export function update(value) { return value * 2; }", "value": 2}},
             "objects": [{"id": 1, "name": "Image"}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.model.store!.scene[0, SceneScriptSceneField.bloomhdrstrength.offset], 8,
                       "2 × 2 × 2: the live value chains")
        XCTAssertEqual(f.evaluate("'bloomhdrstrength' in thisScene")?.toBool(), false, "not a member")
        XCTAssertTrue(f.errors.isEmpty, "\(f.errors)")
    }

    // MARK: - User properties (S8)

    func testUserBoundScriptPropertiesAreInjectedBeforeApplyUserProperties() throws {
        _ = try Fixtures.assets()
        let properties = try SceneScriptUserProperties.parsing("""
            {"bars": {"type": "slider", "value": 12}, "tint": {"type": "color", "value": "1 0 0"}}
            """)
        let f = try fixture()
        try f.load(scene(object: 1, field: "alpha", value: "1", script: """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: 'barAmount', value: 32, min: 1, max: 99 })
                .addColor({ name: 'color', value: new Vec3(0, 0, 1) })
                .addText({ name: 'label', value: 'x' })
                .finish();
            export function init() { shared.initBars = scriptProperties.barAmount; }
            export function applyUserProperties(changed) {
                shared.log = (shared.log || []).concat([scriptProperties.barAmount + ':' + Object.keys(changed).sort().join('+')]);
                shared.colorIsVec3 = scriptProperties.color instanceof Vec3;
                shared.color = scriptProperties.color.x;
            }
            """, extra: """
            , "scriptproperties": {"barAmount": {"user": "bars", "value": 32}, "color": {"user": "tint", "value": "0 0 1"}, "label": "y"}
            """), userProperties: properties)
        XCTAssertEqual(f.evaluate("shared.initBars")?.toInt32(), 12, "S8: the user's value before init")
        XCTAssertEqual(f.evaluate("shared.colorIsVec3")?.toBool(), true)
        var changed = properties
        changed.set("bars", to: .number(40))
        f.runtime.userPropertiesDidChange(changed.payload(only: ["bars"]))
        f.frames(1)
        XCTAssertEqual(f.evaluate("shared.log.join()")?.toString(), "12:bars+tint,40:bars")
        XCTAssertEqual(f.evaluate("shared.color")?.toDouble(), 1)
    }

    func testAUserBoundValueTakesTheNewValueBeforeUpdate() throws {
        let properties = try SceneScriptUserProperties.parsing("""
            {"show": {"type": "bool", "value": false}, "move": {"type": "combo", "value": "2"}}
            """)
        // The renderer describes objects with their user-resolved values (the table is the live value).
        let hidden = SceneScriptObjectDescription.make(.image, id: 1, name: "Image", values: [.visible: [0]])
        let hiddenText = SceneScriptObjectDescription.make(.text, id: 2, name: "Clock", values: [.visible: [0]])
        let f = try SceneScriptBindingFixture(objects: [hidden, hiddenText])
        try f.load("""
            {"objects": [{"id": 1, "name": "Image",
              "visible": {"script": "export function update(value) { shared.seen = value; return value; }", "user": "show", "value": true},
              "alpha": {"script": "export function update(value) { return value; }", "value": 1}},
             {"id": 2, "name": "Clock",
              "visible": {"script": "export function update(value) { return value; }", "user": {"name": "move", "condition": "1"}, "value": true}}]}
            """, userProperties: properties)
        XCTAssertEqual(f.value("Image", "visible")?.toBool(), false, "the user's value, not the authored one")
        XCTAssertEqual(f.value("Clock", "visible")?.toBool(), false, "a condition compares the property's text")
        var changed = properties
        changed.set("show", to: .bool(true))
        changed.set("move", to: .string("1"))
        f.runtime.userPropertiesDidChange(changed.payload(only: ["show", "move"]))
        f.frames(1)
        XCTAssertEqual(f.evaluate("shared.seen")?.toBool(), true)
        XCTAssertEqual(f.table(0, .visible), [1])
        XCTAssertEqual(f.table(1, .visible), [1])
    }

    func testTheUserPropertiesPayloadIsWEsRawForm() throws {
        _ = try Fixtures.assets()
        var properties = try SceneScriptUserProperties.parsing("""
            {"tint": {"type": "color", "value": "1 0.5 0", "text": "Tint", "order": 1},
             "go": {"type": "usershortcut", "value": "", "isbound": false}}
            """)
        // A user shortcut reads from the user's binding (WE's stored form), never project.json.
        properties.setStoredValues(["go": "file:a1b2c3:/Applications/a.app|-x"])
        let payload = properties.payload()
        XCTAssertEqual((payload["tint"] as? [String: Any])?["type"] as? String, "color")
        XCTAssertEqual((payload["tint"] as? [String: Any])?["value"] as? String, "1 0.5 0")
        XCTAssertNil((payload["tint"] as? [String: Any])?["text"])
        XCTAssertEqual((payload["go"] as? [String: Any])?["isbound"] as? Bool, true)
        XCTAssertNil((payload["go"] as? [String: Any])?["value"], "the binding itself stays out of scripts")
        let f = try fixture()
        try f.load(scene(object: 1, field: "alpha", value: "1", script: """
            export function applyUserProperties(changed) { shared.tint = changed.tint; shared.file = changed.go.file; }
            """), userProperties: properties)
        XCTAssertEqual(vector(f.evaluate("shared.tint")), [1, 0.5, 0], "WE's convertUserProperties makes colours Vec3s")
        XCTAssertEqual(f.evaluate("shared.file")?.toString(), "a.app")
        XCTAssertEqual(vector(f.evaluate("engine.userProperties.tint")), [1, 0.5, 0])
    }
}
