import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// One test per way the corpus binds scripts (docs/scenescript-plan.md §2, WP8), each a synthetic
/// scene.json whose script follows the named corpus script (`corpus/scripts/<hash>.js`), run
/// through `SceneScriptSiteBuilder` and the binding like a wallpaper.
final class SceneScriptBindingCorpusPatternTests: XCTestCase {
    private static let multiplyAnimation = SceneScriptAnimationDescription(
        name: "pulse", fps: 30, frameCount: 30, duration: 1, property: "multiply")

    private static let objects: [SceneScriptObjectDescription] = [
        .make(.image, id: 1, name: "Layer", values: [.origin: [0, 0, 0], .alpha: [0]], effects: [
            .init(name: "cover", visible: false,
                  materials: [.init(constants: [.init(name: "multiply", value: [1])], animations: [multiplyAnimation])]),
            .init(name: "glow", visible: true, materials: [.init(constants: [])]),
        ]),
        .make(.text, id: 2, name: "Clock", strings: [.text: ""]),
        .make(.particle, id: 3, name: "Sparks", values: [.instanceRate: [2], .instanceLifetime: [1.5]]),
        .make(.sound, id: 4, name: "slap"),
        .make(.image, id: 5, name: "userProperties", values: [.origin: [1000, 900, 0], .scale: [2, 2, 2]]),
        .make(.image, id: 10, name: "Dancer1"),
        .make(.image, id: 11, name: "Dancer2"),
    ]

    private func fixture(now: @escaping () -> Date = Date.init) throws -> SceneScriptBindingFixture {
        try SceneScriptBindingFixture(objects: Self.objects, settings: [.bloomstrength: [1.5]], now: now)
    }

    private func bound(_ script: String, value: String, extra: String = "") -> String {
        "{\"script\": \(SceneScriptBindingTests.literal(script)), \"value\": \(value)\(extra)}"
    }

    private func vector(_ value: JSValue?) -> [Double] {
        guard let value, value.isObject else { return [] }
        return ["x", "y", "z"].compactMap { value.forProperty($0)?.isNumber == true ? value.forProperty($0)?.toDouble() : nil }
    }

    private func assertNoErrors(_ f: SceneScriptBindingFixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(f.errors.isEmpty, "\(f.errors)", file: file, line: line)
    }

    // MARK: - text (143 sites)

    /// ade9bddce036, 49ddf6ffcdf7: a clock whose format comes from `scriptProperties`, one of them
    /// bound to a user property.
    func testTextClockFormattedByScriptProperties() throws {
        _ = try Fixtures.assets()
        let properties = try SceneScriptUserProperties.parsing(#"{"showseconds": {"type": "bool", "value": false}}"#)
        let f = try fixture()
        let script = """
            'use strict';
            export var scriptProperties = createScriptProperties()
                .addText({ name: 'delimiter', label: 'Delimiter', value: '-' })
                .addCheckbox({ name: 'showSeconds', label: 'Seconds', value: true })
                .finish();
            function pad(n) { return n < 10 ? '0' + n : String(n); }
            /** @param {String} value (for property 'text') */
            export function update(value) {
                const d = new Date(2026, 0, 2, 3, 4, 5);
                let text = pad(d.getHours()) + scriptProperties.delimiter + pad(d.getMinutes());
                if (scriptProperties.showSeconds) text += scriptProperties.delimiter + pad(d.getSeconds());
                return text;
            }
            """
        try f.load("""
            {"objects": [{"id": 2, "name": "Clock", "text": \(bound(script, value: "\"<Clock>\"", extra: """
            , "scriptproperties": {"delimiter": ":", "showSeconds": {"user": "showseconds", "value": true}}
            """))}]}
            """, userProperties: properties)
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Clock').text")?.toString(), "03:04")
        var changed = properties
        changed.set("showseconds", to: .bool(true))
        f.runtime.userPropertiesDidChange(changed.payload(only: ["showseconds"]))
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Clock').text")?.toString(), "03:04:05")
        assertNoErrors(f)
    }

    /// The 33 `mediaPropertiesChanged` text sites: the callback writes `thisLayer.text`, `update`
    /// passes the value through.
    func testTextFollowsTheMediaTitle() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 2, "name": "Clock", "text": \(bound("""
            export function mediaPropertiesChanged(event) { thisLayer.text = event.title; }
            export function update(value) { return value; }
            """, value: "\"\""))}]}
            """)
        f.evaluate("__rt.broadcast('mediaPropertiesChanged', [{ title: 'Song' }])")
        f.frames(1)
        XCTAssertEqual(f.value("Clock", "text")?.toString(), "Song")
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Clock').text")?.toString(), "Song")
        assertNoErrors(f)
    }

    // MARK: - effect constants (90 sites)

    /// daf50e8c7157 (15 sites): `thisObject` is the material, and `getAnimation()` without a name
    /// is the constant's own timeline.
    func testShaderConstantRestartsItsOwnAnimationOnAThumbnail() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "effects": [{"passes": [{"constantshadervalues": {"multiply": \(bound("""
            export function mediaThumbnailChanged(event) {
                if (event.hasThumbnail) {
                    var anim = thisObject.getAnimation();
                    anim.stop();
                    anim.play();
                }
            }
            """, value: "1"))}}]}]}]}
            """)
        _ = f.objectHost.takeCommands()
        f.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true }])")
        f.frames(1)
        let actions = f.objectHost.takeCommands().compactMap { command -> SceneScriptObjectCommand.AnimationAction? in
            if case .animation(_, let action) = command { return action }
            return nil
        }
        XCTAssertEqual(actions, [.stop, .play])
        assertNoErrors(f)
    }

    /// 4181ca8b13fd (`multiply` and the particle overrides): a value from `WEMath` and the time of day.
    func testShaderConstantFromWEMathAndTheTimeOfDay() throws {
        _ = try Fixtures.assets()
        let night = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 23)) ?? Date()
        let f = try fixture(now: { night })
        let script = """
            'use strict';
            import * as WEMath from 'WEMath';
            const START_HOUR = 7;
            const END_HOUR = 18;
            export function update(value) {
                return Math.max(
                    WEMath.smoothStep(START_HOUR / 24, (START_HOUR - 0.004) / 24, engine.timeOfDay),
                    WEMath.smoothStep((END_HOUR - 0.004) / 24, END_HOUR / 24, engine.timeOfDay));
            }
            """
        try f.load("""
            {"objects": [
              {"id": 1, "name": "Layer", "effects": [{"passes": [{"constantshadervalues": {"multiply": \(bound(script, value: "0"))}}]}]},
              {"id": 3, "name": "Sparks", "instanceoverride": {"alpha": \(bound(script, value: "0")), "colorn": \(bound(script, value: "\"0 0 0\""))}}]}
            """)
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('Layer').getEffect(0).getMaterial(0).multiply")?.toDouble(), 1)
        XCTAssertEqual(f.table(2, .instanceAlpha), [1])
        XCTAssertEqual(f.table(2, .instanceColorn), [1], "colorn is a Number in lib.sceneScript.d.ts")
        assertNoErrors(f)
    }

    // MARK: - visible (70 sites)

    /// 298c77c253bb: `update` passes the value through; a click plays a sound found by name.
    func testVisiblePassThroughWithACursorCallback() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "visible": \(bound("""
            export function update(value) { return value; }
            export function cursorClick(event) { thisScene.getLayer("slap").play(); }
            """, value: "true"))}]}
            """)
        f.frames(3)
        XCTAssertEqual(f.table(0, .visible), [1])
        f.evaluate("__rt.broadcast('cursorClick', [{}])")
        f.frames(1)
        XCTAssertTrue(f.objectHost.takeCommands().contains { command in
            if case .sound(3, .play) = command { return true }
            return false
        })
        assertNoErrors(f)
    }

    /// a2bd9a0afb5f / 8e2e61a2a540 (Dance Club): each dancer is visible when a combo equals its
    /// condition, and carries literal `scriptproperties`.
    func testVisibleFollowsAUserConditionPerLayer() throws {
        _ = try Fixtures.assets()
        let properties = try SceneScriptUserProperties.parsing(#"{"dance_move": {"type": "combo", "value": "1"}}"#)
        let f = try SceneScriptBindingFixture(objects: [
            .make(.image, id: 10, name: "Dancer1", values: [.visible: [1]]),
            .make(.image, id: 11, name: "Dancer2", values: [.visible: [0]]),
        ])
        let script = """
            export var scriptProperties = createScriptProperties()
                .addSlider({ name: 'minvalue', value: 0.8, min: 0, max: 3 })
                .addCheckbox({ name: 'anim', value: false })
                .finish();
            export function update(value) { shared['seen' + thisLayer.name] = value; shared.anim = scriptProperties.anim; return value; }
            """
        let dancer = { (id: Int, condition: String) in
            "{\"id\": \(id), \"name\": \"Dancer\(id - 9)\", \"visible\": \(self.bound(script, value: "false", extra: """
            , "user": {"name": "dance_move", "condition": "\(condition)"}, "scriptproperties": {"anim": true, "minvalue": 0.80000001}
            """))}"
        }
        try f.load("{\"objects\": [\(dancer(10, "1")), \(dancer(11, "2"))]}", userProperties: properties)
        f.frames(1)
        XCTAssertEqual(f.evaluate("[shared.seenDancer1, shared.seenDancer2, shared.anim].join()")?.toString(), "true,false,true")
        var changed = properties
        changed.set("dance_move", to: .string("2"))
        f.runtime.userPropertiesDidChange(changed.payload(only: ["dance_move"]))
        f.frames(1)
        XCTAssertEqual(f.table(0, .visible), [0])
        XCTAssertEqual(f.table(1, .visible), [1])
        assertNoErrors(f)
    }

    /// 8bb9b9a54120: a `visible` script WE can't compile either keeps the authored value.
    func testAScriptThatDoesNotCompileKeepsTheAuthoredValue() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "visible": \(bound("export function update(value) { return 'broken\nstring'; }", value: "true"))}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.table(0, .visible), [1])
        XCTAssertEqual(f.errors.map(\.kind), [.compile])
    }

    // MARK: - origin (56 sites)

    /// 37b27aea0c2b: `init` reads another layer found by name, `applyUserProperties` moves the layer.
    func testOriginMovedFromApplyUserProperties() throws {
        _ = try Fixtures.assets()
        let properties = try SceneScriptUserProperties.parsing(#"{"scale": {"type": "slider", "value": 1}}"#)
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "origin": \(bound("""
            var HalfX = 0
            var HalfY = 0
            export function init(value) {
                var userProperties = thisScene.getLayer("userProperties")
                HalfX = userProperties.origin.x
                HalfY = userProperties.origin.y
                return value;
            }
            export function applyUserProperties(changedUserProperties) {
                if (changedUserProperties.hasOwnProperty('scale')) {
                    var userScale = thisScene.getLayer("userProperties").scale;
                    thisLayer.origin = new Vec3(HalfX - ((HalfX - 1380) * userScale.x),
                        HalfY - ((HalfY - 1130) * userScale.x), thisLayer.origin.z)
                }
            }
            """, value: "\"0 0 0\""))}]}
            """, userProperties: properties)
        XCTAssertEqual(f.table(0, .origin), [1760, 1360, 0], "applyUserProperties(all) at load")
        f.frames(1)
        XCTAssertEqual(f.table(0, .origin), [1760, 1360, 0])
        assertNoErrors(f)
    }

    // MARK: - effects[i].visible (54 sites)

    /// c6d2821a99fa (15 sites): `thisObject.visible = event.hasThumbnail`; `thisObject` is the effect.
    func testEffectVisibilityFollowsTheThumbnail() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        let script = "export function mediaThumbnailChanged(event) { thisObject.visible = event.hasThumbnail; }"
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "effects": [{"visible": \(bound(script, value: "false"))}, {"visible": \(bound(script, value: "true"))}]}]}
            """)
        f.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true }])")
        f.frames(1)
        XCTAssertEqual(f.evaluate("[0, 1].map(function (i) { return thisScene.getLayer('Layer').getEffect(i).visible; }).join()")?.toString(),
                       "true,true")
        f.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: false }])")
        f.frames(1)
        XCTAssertEqual(f.evaluate("[0, 1].map(function (i) { return thisScene.getLayer('Layer').getEffect(i).visible; }).join()")?.toString(),
                       "false,false")
        assertNoErrors(f)
    }

    // MARK: - alpha (43 sites)

    /// 66d86c32cce9: an accumulator gated by `shared`, which another script sets.
    func testAlphaAccumulatesWhileASharedFlagIsSet() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer",
              "visible": \(bound("export function update(value) { shared.catE = engine.runtime < 0.5 ? 1 : 0; return value; }", value: "true")),
              "alpha": \(bound("""
            let k=0.75;
            export function update(value) {
                if(shared.catE==1) { if(value<k) {value=value+0.01} } else { value=0 }
                return value;
            }
            """, value: "0"))}]}
            """)
        f.frames(10)
        XCTAssertEqual(Double(f.table(0, .alpha)[0]), 0.1, accuracy: 1e-5, "0.01 per frame from the live value")
        f.frames(30)
        XCTAssertEqual(f.table(0, .alpha), [0])
        assertNoErrors(f)
    }

    // MARK: - scale (26 sites)

    /// 1b3a92cc7a8f: audio bars scaled between two `scriptProperties` sliders.
    func testScaleFollowsTheAudioBetweenScriptPropertyBounds() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "scale": \(bound("""
            export var scriptProperties = createScriptProperties()
                .addCheckbox({ name: 'active', value: true })
                .addSlider({ name: 'hoScaleMin', value: 1, min: 0.1, max: 10 })
                .addSlider({ name: 'hoScaleMax', value: 1.2, min: 0.1, max: 10 })
                .finish();
            const audio = engine.registerAudioBuffers(engine.AUDIO_RESOLUTION_16);
            export function update(value) {
                if (!scriptProperties.active) return;
                const level = audio.average[0];
                const s = scriptProperties.hoScaleMin + (scriptProperties.hoScaleMax - scriptProperties.hoScaleMin) * level;
                return new Vec3(s, s, 1);
            }
            """, value: "\"1 1 1\"", extra: ", \"scriptproperties\": {\"hoScaleMax\": 3}"))}]}
            """)
        f.frames(1)
        XCTAssertEqual(f.table(0, .scale), [1, 1, 1])
        f.audio.set(level: 0.5)
        f.frames(1)
        XCTAssertEqual(f.table(0, .scale), [2, 2, 1])
        assertNoErrors(f)
    }

    // MARK: - angles (18 sites)

    /// 3cba3c21bfe8: the argument is changed and returned; angles are degrees.
    func testAnglesRotateWithTheRuntime() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer", "angles": \(bound("""
            let rotationSpeed = 2
            export function update(value) {
                value.z = (engine.runtime * rotationSpeed) % 1.0 * 360;
                return value;
            }
            """, value: "\"0 0 0\""))}]}
            """)
        f.frames(7)
        let expected = f.evaluate("(engine.runtime * 2) % 1.0 * 360")?.toDouble() ?? -1
        XCTAssertEqual(vector(f.evaluate("thisScene.getLayer('Layer').angles"))[2], expected, accuracy: 1e-3)
        XCTAssertEqual(Double(f.table(0, .angles)[2]), expected * .pi / 180, accuracy: 1e-5)
        assertNoErrors(f)
    }

    // MARK: - color (4 sites)

    /// 7c6eb650a61e: returns `shared.accentColor`, undefined until a media script sets it.
    func testColorFromASharedAccentColor() throws {
        _ = try Fixtures.assets()
        let f = try SceneScriptBindingFixture(objects: [.make(.image, id: 1, name: "Layer", values: [.color: [1, 1, 1]])])
        try f.load("""
            {"objects": [{"id": 1, "name": "Layer",
              "visible": \(bound("export function mediaThumbnailChanged(event) { shared.accentColor = event.primaryColor; }", value: "true")),
              "color": \(bound("export function update(value) { return shared.accentColor; }", value: "\"1 1 1\""))}]}
            """)
        f.frames(2)
        XCTAssertEqual(f.table(0, .color), [1, 1, 1], "undefined keeps the colour")
        f.evaluate("__rt.broadcast('mediaThumbnailChanged', [{ hasThumbnail: true, primaryColor: new Vec3(0.25, 0.5, 0.75) }])")
        f.frames(1)
        XCTAssertEqual(f.table(0, .color), [0.25, 0.5, 0.75])
        assertNoErrors(f)
    }

    // MARK: - instanceoverride (22 sites)

    /// 9a297f93b1ff (rate) and 72e103064d75 (lifetime): `init` keeps the authored value, `update`
    /// scales it by the audio.
    func testParticleOverridesScaledByTheAudio() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        func script(resolution: Int, band: Int, minimum: Double, maximum: Double) -> String {
            """
            let audioBuffer = engine.registerAudioBuffers(\(resolution));
            let smoothValue = 0;
            let initialValue;
            export function update() {
                smoothValue += (audioBuffer.average[\(band)] - smoothValue) * engine.frametime * 16;
                smoothValue = Math.min(1.0, smoothValue);
                return initialValue * (smoothValue * (\(maximum) - \(minimum)) + \(minimum));
            }
            export function init(value) { initialValue = value; }
            """
        }
        try f.load("""
            {"objects": [{"id": 3, "name": "Sparks", "instanceoverride": {
              "rate": \(bound(script(resolution: 16, band: 0, minimum: 1, maximum: 2.5), value: "2")),
              "lifetime": \(bound(script(resolution: 64, band: 1, minimum: 0, maximum: 1), value: "1.5"))}}]}
            """)
        f.frames(1)
        XCTAssertEqual(f.table(2, .instanceRate), [2], "the live value init got, times the minimum")
        XCTAssertEqual(f.table(2, .instanceLifetime), [0])
        f.audio.set(level: 1)
        f.frames(120)
        XCTAssertEqual(Double(f.table(2, .instanceRate)[0]), 5, accuracy: 0.01)
        XCTAssertEqual(Double(f.table(2, .instanceLifetime)[0]), 1.5, accuracy: 0.01)
        assertNoErrors(f)
    }

    // MARK: - general (2 sites)

    /// 992b23de26f1: `general.bloomstrength` follows the audio from the value `init` got.
    func testBloomStrengthFollowsTheAudio() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        try f.load("""
            {"general": {"bloomstrength": \(bound("""
            let audioBuffer = engine.registerAudioBuffers(16);
            var smoothValue = 0;
            var initialValue;
            export function update() {
                smoothValue += (audioBuffer.average[0] - smoothValue) * engine.frametime * 16;
                smoothValue = Math.min(1.0, smoothValue);
                return initialValue * (smoothValue * 2);
            }
            export function init(value) { initialValue = value; }
            """, value: "1.5"))}, "objects": []}
            """)
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.bloomstrength")?.toDouble(), 0)
        f.audio.set(level: 1)
        f.frames(120)
        XCTAssertEqual(f.evaluate("thisScene.bloomstrength")?.toDouble() ?? 0, 3, accuracy: 0.01)
        assertNoErrors(f)
    }

    /// 1e2bc795b0cf: `general.camerashake` bound to a user property and a script that returns
    /// nothing until another user property turns it on.
    func testCameraShakeFromAUserPropertyAndTheAudio() throws {
        _ = try Fixtures.assets()
        let properties = try SceneScriptUserProperties.parsing("""
            {"camera_shake": {"type": "bool", "value": true}, "audiocheckbox": {"type": "bool", "value": false}}
            """)
        let f = try SceneScriptBindingFixture(objects: [], settings: [.camerashake: [1]])
        try f.load("""
            {"general": {"camerashake": \(bound("""
            let isAudio = false;
            let audio = engine.registerAudioBuffers(16);
            export function update(value) {
                if (isAudio) {
                    if (audio.average[0] > 0.9) { value = true; } else { value = false; }
                    return value;
                }
            }
            export function applyUserProperties(changedUserProperties) {
                if (changedUserProperties.audiocheckbox != undefined)
                    isAudio = changedUserProperties.audiocheckbox;
            }
            """, value: "false", extra: ", \"user\": \"camera_shake\""))}, "objects": []}
            """, userProperties: properties)
        f.frames(2)
        XCTAssertEqual(f.evaluate("thisScene.camerashake")?.toBool(), true, "the user's value while the script returns nothing")
        var changed = properties
        changed.set("audiocheckbox", to: .bool(true))
        f.runtime.userPropertiesDidChange(changed.payload(only: ["audiocheckbox"]))
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.camerashake")?.toBool(), false, "silence")
        f.audio.set(level: 1)
        f.frames(1)
        XCTAssertEqual(f.evaluate("thisScene.camerashake")?.toBool(), true)
        assertNoErrors(f)
    }
}
