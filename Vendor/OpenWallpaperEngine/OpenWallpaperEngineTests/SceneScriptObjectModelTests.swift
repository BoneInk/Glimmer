import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// The SceneScript object model (docs/scenescript-plan.md WP7): live layers over shared memory,
/// `thisObject` scopes, and the native commands scripts issue.
final class SceneScriptObjectModelTests: XCTestCase {
    static func sceneDescription() -> SceneScriptSceneDescription {
        let tint = SceneScriptObjectDescription.Effect(
            name: "tint", visible: true,
            materials: [.init(constants: [.init(name: "multiply", value: [0.5]), .init(name: "color", value: [1, 0, 0]),
                                          .init(name: "Bar Color", value: [0, 1, 0])],
                              animations: [.init(name: "fade", fps: 30, frameCount: 60, duration: 2, property: "multiply")])],
            animations: [.init(name: "blink", fps: 30, frameCount: 30, duration: 1, property: "visible")])
        let background = SceneScriptObjectDescription.make(
            .image, id: 1, name: "background",
            values: [.origin: [10, 20, 0], .angles: [0, 0, .pi / 2]],
            strings: [.alignment: "center"], effects: [tint],
            animations: [.init(name: "bounce", fps: 30, frameCount: 90, duration: 3, property: "alpha")],
            textureAnimation: .init(name: "", fps: 8, frameCount: 8, duration: 1, playing: true),
            config: #"{"id":1,"name":"background","image":"models/background.json","origin":"10 20 0"}"#)
        let clock = SceneScriptObjectDescription.make(.text, id: 2, name: "clock", parentID: 1,
                                                      values: [.pointsize: [32]], strings: [.text: "12:00"])
        let music = SceneScriptObjectDescription.make(.sound, id: 3, name: "music", values: [.volume: [0.5]])
        let snow = SceneScriptObjectDescription.make(.particle, id: 4, name: "snow")
        let group = SceneScriptObjectDescription.make(.group, id: 5, name: "group")
        return SceneScriptSceneDescription(
            objects: [background, clock, music, snow, group], settings: [.bloomstrength: [2]],
            animations: [.init(name: "pulse", fps: 30, frameCount: 30, duration: 1, property: "bloomstrength")])
    }

    /// `createLayer` descriptions: an image for assets and copies, a text layer when the
    /// configuration has `text` (like WE).
    static func describe(_ source: SceneScriptLayerSource) -> SceneScriptObjectDescription? {
        switch source {
        case .asset(let path, _):
            guard path.hasSuffix("bar.json") else { return nil }
            return .make(.image, id: 100, name: "bar", values: [.scale: [1, 1, 1]])
        case .configuration(let json):
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let kind: SceneScriptObjectDescription.Kind = object["text"] != nil ? .text : .image
            return .make(kind, id: 200, name: object["name"] as? String ?? "", config: json)
        case .copy:
            return .make(.image, id: 300, name: "copy")
        }
    }

    private func fixture(capacity: SceneScriptObjectStore.Capacity = .standard) throws -> SceneScriptObjectFixture {
        try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: Self.sceneDescription(), describe: Self.describe),
                                     capacity: capacity)
    }

    // MARK: - Shared memory

    func testLayerMembersReadAndWriteTheObjectTable() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate("var bg = thisScene.getLayer('background');")
        XCTAssertEqual(f.evaluate("[bg.origin.x, bg.origin.y, Math.round(bg.angles.z * 1000) / 1000].join(',')")?.toString(),
                       "10,20,90", "angles are degrees at the API, radians in the table")
        XCTAssertEqual(f.evaluate("bg.origin instanceof Vec3 && bg.parallaxDepth instanceof Vec2")?.toBool(), true)
        XCTAssertEqual(f.evaluate("bg.origin.add(new Vec3(1)).x")?.toDouble(), 11, "WE's Vec3 methods work on members")

        f.evaluate("bg.origin = new Vec3(1, 2, 3); bg.angles = new Vec3(0, 0, 180); bg.parallaxDepth = new Vec2(0, 0);")
        XCTAssertEqual(f.table(0, .origin), [1, 2, 3])
        XCTAssertEqual(Double(f.table(0, .angles)[2]), Double.pi, accuracy: 1e-5)
        XCTAssertEqual(f.table(0, .parallaxDepth), [0, 0])
        XCTAssertEqual(f.store.table.dirty[0], 1, "a script write marks the slot dirty")
        XCTAssertEqual(f.store.table.dirty[1], 0)

        f.store.table[0, .alpha] = [0.25]
        XCTAssertEqual(f.evaluate("bg.alpha")?.toDouble(), 0.25, "the renderer's writes are what scripts read")
        XCTAssertEqual(f.evaluate("var o = bg.origin; o.x = 99; bg.origin.x")?.toDouble(), 1, "getters return copies")

        let matrix = SceneScriptObjectTable.index(slot: 0, field: SceneScriptObjectTable.Layout.worldMatrix)
        f.store.table.values[matrix + 12] = 7
        XCTAssertEqual(f.evaluate("var m = bg.getTransformMatrix(); (m instanceof Mat4) + ' ' + m.m[12] + ' ' + m.m[0]")?
            .toString(), "true 7 1")

        f.evaluate("bg.size = new Vec2(5, 5)")
        XCTAssertEqual(f.table(0, .size), [0, 0], "size is read-only")
        XCTAssertEqual(f.evaluate("thisScene.getLayer('clock').pointsize")?.toDouble(), 32)
        XCTAssertEqual(f.evaluate("thisScene.getLayer('clock').text")?.toString(), "12:00")
    }

    /// WE's own WEMath and WEVector code works on members: their bodies are evaluated here with
    /// `export`/`import` removed (the module compiler is WP3's), everything else unmodified.
    func testMembersInteroperateWithWEVectorAndWEMath() throws {
        _ = try Fixtures.assets()
        let modules = SceneScriptPrelude.load().modules
        let weMath = try XCTUnwrap(modules.first { $0.name == "wemath" }).source
        let weVector = try XCTUnwrap(modules.first { $0.name == "wevector" }).source
        func body(_ source: String) -> String {
            source.components(separatedBy: "\n").filter { !$0.hasPrefix("import ") }.joined(separator: "\n")
                .replacingOccurrences(of: "export ", with: "")
        }
        let f = try fixture()
        f.evaluate("""
            var WEMath = (function () { \(body(weMath))
                return { deg2rad: deg2rad, rad2deg: rad2deg, smoothStep: smoothStep, mix: mix }; })();
            var WEVector = (function () { \(body(weVector))
                return { angleVector2: angleVector2, vectorAngle2: vectorAngle2 }; })();
            var bg = thisScene.getLayer(0);
            bg.parallaxDepth = WEVector.angleVector2(90);
            bg.angles = new Vec3(0, 0, WEVector.vectorAngle2(new Vec2(0, 1)) + 90);
            bg.alpha = WEMath.smoothStep(0, 1, 0.5);
            """)
        XCTAssertTrue(f.table(0, .parallaxDepth)[0].magnitude < 1e-6)
        XCTAssertEqual(f.table(0, .parallaxDepth)[1], 1)
        XCTAssertEqual(Double(f.table(0, .angles)[2]), Double.pi, accuracy: 1e-5)
        XCTAssertEqual(f.table(0, .alpha), [0.5])
        XCTAssertEqual(f.evaluate("Math.round(WEVector.vectorAngle2(bg.parallaxDepth))")?.toInt32(), 90)
        XCTAssertEqual(f.evaluate("bg.getTransformMatrix().translation() instanceof Vec3")?.toBool(), true)
    }

    func testWritesFollowWEConverter() throws {
        let f = try fixture()
        f.evaluate("var bg = thisScene.getLayer(0);")
        f.evaluate("bg.scale = 2")
        XCTAssertEqual(f.table(0, .scale), [2, 2, 2], "a number is broadcast to every component")
        f.evaluate("bg.origin = new Vec2(1, 2); bg.origin = 'x'; bg.origin = {x: 1, y: 2}; bg.alpha = '0.5';")
        XCTAssertEqual(f.table(0, .origin), [10, 20, 0], "values WE rejects leave the property unchanged")
        XCTAssertEqual(f.table(0, .alpha), [1])
        f.evaluate("bg.alpha = NaN; bg.visible = false;")
        XCTAssertTrue(f.table(0, .alpha)[0].isNaN, "NaN passes WE's number check and is written")
        XCTAssertEqual(f.table(0, .visible), [0])
        XCTAssertEqual(f.evaluate("bg.visible")?.toBool(), false)
    }

    // MARK: - Scripts

    func testScriptWritesStickAndLayersKeepTheirIdentity() throws {
        let f = try fixture()
        f.add("bg-visible", slot: 0, binding: .layer(slot: 0, property: "visible"), initialValue: true, """
            function init(value) {
                shared.same = thisLayer === thisScene.getLayer('background') && thisObject === thisLayer
                    && thisLayer === thisScene.getLayer(0) && thisLayer === thisScene.getLayerByID('1')
                    && thisLayer === thisScene.getLayerByID(1);
            }
            function update(value) { thisLayer.alpha = thisLayer.alpha * 0.5; return value; }
            """)
        f.runtime.load()
        f.runtime.frame(deltaTime: 1.0 / 60)
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.evaluate("shared.same")?.toBool(), true)
        XCTAssertEqual(f.table(0, .alpha), [0.25])
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")

        XCTAssertEqual(f.evaluate("thisScene.getLayerCount()")?.toInt32(), 5)
        XCTAssertEqual(f.evaluate("thisScene.enumerateLayers().map(l => l.name).join(',')")?.toString(),
                       "background,clock,music,snow,group", "draw order")
        XCTAssertEqual(f.evaluate("thisScene.getLayerIndex('clock') + ',' + thisScene.getLayerIndex(thisScene.getLayer('snow'))")?
            .toString(), "1,3")
        XCTAssertEqual(f.evaluate("thisScene.getLayer('clock').getParent() === thisScene.getLayer('background')")?.toBool(), true)
        XCTAssertEqual(f.evaluate("typeof thisScene.getLayer('background').getParent()")?.toString(), "undefined")
        XCTAssertEqual(f.evaluate("thisScene.getLayer('background').getChildren().map(l => l.name).join()")?.toString(), "clock")
        XCTAssertEqual(f.evaluate("thisScene.getLayer('nope') === null && thisScene.getLayer(42) === null")?.toBool(), true)
        XCTAssertEqual(f.model.slot(forObjectID: 3), 2)
    }

    func testStringWritesReachTheRendererOncePerFrame() throws {
        let f = try fixture()
        f.add("clock-text", slot: 1, """
            function update(value) {
                thisLayer.text = 'a'; thisLayer.text = 'b'; thisLayer.text = 7;
                thisLayer.name = 'renamed';
            }
            """)
        f.runtime.load()
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [.setString(slot: 1, field: .text, value: "7"),
                                               .setString(slot: 1, field: .name, value: "renamed")])
        XCTAssertEqual(f.evaluate("thisScene.getLayer('renamed').text")?.toString(), "7")
    }

    // MARK: - thisObject scopes

    func testEffectAndMaterialScopes() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.add("effect-visible", slot: 0, binding: .effect(slot: 0, effect: 0, property: "visible"), initialValue: true, """
            function init(value) {
                shared.isEffect = thisObject === thisLayer.getEffect(0) && thisObject === thisLayer.getEffect('tint');
                shared.effectAnimation = thisObject.getAnimation().name;
                thisObject.visible = false;
            }
            """)
        f.add("multiply", slot: 0, binding: .material(slot: 0, effect: 0, material: 0, constant: "multiply"),
              initialValue: 0.5, """
            function init(value) {
                shared.isMaterial = thisObject === thisLayer.getEffect(0).getMaterial(0);
                shared.multiply = thisObject.multiply;
                shared.barColor = thisObject['Bar Color'].y;
                thisObject.multiply = 0.75;
                thisObject.color = new Vec3(0, 0, 1);
                thisObject.getAnimation().play();
                shared.named = thisObject.getAnimation('fade') === thisObject.getAnimation();
            }
            """)
        f.add("alpha", slot: 0, binding: .layer(slot: 0, property: "alpha"), initialValue: 1, """
            function init(value) {
                shared.alphaAnimation = thisObject.getAnimation().name;
                shared.noDefault = thisScene.getLayer('clock').getAnimation() === null;
            }
            """)
        f.runtime.load()
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(f.evaluate("[shared.isEffect, shared.isMaterial, shared.named, shared.noDefault].join()")?.toString(),
                       "true,true,true,true")
        XCTAssertEqual(f.evaluate("shared.effectAnimation + ',' + shared.alphaAnimation")?.toString(), "blink,bounce")
        XCTAssertEqual(f.evaluate("shared.multiply + ',' + shared.barColor")?.toString(), "0.5,1")
        XCTAssertEqual(f.store.effects[0, 0], 0, "thisObject.visible on an effect hides the effect")
        XCTAssertEqual(f.store.effects.dirty[0], 1)
        XCTAssertEqual(f.evaluate("thisScene.getLayer(0).getEffect(0).getMaterial(0).getMaterialProperty('multiply')")?
            .toDouble(), 0.75)

        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = f.host.takeCommands()
        XCTAssertEqual(Array(commands.prefix(2)), [
            .setMaterialProperty(slot: 0, effect: 0, material: 0, name: "multiply", value: [0.75]),
            .setMaterialProperty(slot: 0, effect: 0, material: 0, name: "color", value: [0, 0, 1]),
        ])
        guard case .animation(let reference, .play) = commands.last else { return XCTFail("\(commands)") }
        XCTAssertEqual(reference.name, "fade")
        XCTAssertEqual(reference.slot, 0)
        XCTAssertEqual(reference.effect, 0)
        XCTAssertEqual(reference.material, 0)

        f.evaluate("""
            var fx = thisScene.getLayer(0).getEffect(0);
            fx.setMaterialProperty('multiply', 0.1);
            fx.setMaterialProperty('speed', new Vec2(1, 2));
            fx.executeMaterialFunction('reset');
            """)
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [
            .setMaterialProperty(slot: 0, effect: 0, material: nil, name: "multiply", value: [0.1]),
            .setMaterialProperty(slot: 0, effect: 0, material: nil, name: "speed", value: [1, 2]),
            .executeMaterialFunction(slot: 0, effect: 0, name: "reset"),
        ])
        XCTAssertEqual(f.evaluate("fx.getMaterial(0).multiply")?.toDouble() ?? 0, 0.1, accuracy: 1e-6)
        XCTAssertEqual(f.evaluate("fx.getMaterialCount() + ',' + thisScene.getLayer(0).getEffectCount() + ',' + fx.getMaterial(3)")?
            .toString(), "1,1,null")
        // A bound constant's script returns every frame: rewriting what the renderer already holds
        // sends nothing; a constant the material doesn't declare still goes, and a new value does.
        f.evaluate("""
            fx.setMaterialProperty('multiply', 0.1);
            fx.getMaterial(0).multiply = 0.1;
            fx.getMaterial(0).setMaterialProperty('color', new Vec3(0, 0, 1));
            fx.setMaterialProperty('speed', new Vec2(1, 2));
            """)
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [
            .setMaterialProperty(slot: 0, effect: 0, material: nil, name: "speed", value: [1, 2]),
        ])
        f.evaluate("fx.getMaterial(0).multiply = 0.2;")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [
            .setMaterialProperty(slot: 0, effect: 0, material: 0, name: "multiply", value: [0.2]),
        ])
    }

    func testSceneLevelScriptsGetTheScene() throws {
        let f = try fixture()
        f.add("bloom", slot: nil, binding: .scene(property: "bloomstrength"), initialValue: 2, """
            function init(value) {
                shared.scope = (typeof thisLayer) + ',' + (thisObject === thisScene) + ','
                    + (thisObject.getAnimation() === null) + ',' + thisObject.getAnimation('pulse').name;
            }
            """)
        f.add("general", slot: nil, "function init(value) { shared.general = thisObject === thisScene; }")
        f.runtime.load()
        // IScene.getAnimation takes only a name (scenescript64.dll 0x18163613d).
        XCTAssertEqual(f.evaluate("shared.scope")?.toString(), "undefined,true,true,pulse")
        XCTAssertEqual(f.evaluate("shared.general")?.toBool(), true)
    }

    // MARK: - Structure commands

    func testCreateSortAndDestroyLayers() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        // The audio-bar pattern of the corpus (08861b7e67b4, 585203d7f809).
        f.add("bars", slot: 0, """
            function init(value) {
                var index = thisScene.getLayerIndex(thisLayer);
                var bar = thisScene.createLayer('models/bar.json');
                bar.alignment = thisLayer.alignment;
                thisScene.sortLayer(bar, index);
                bar.parallaxDepth = new Vec2(0, 0);
                bar.color = new Vec3(0, 0, 1);
                bar.alpha = 0.5;
                shared.bar = bar;
                shared.fromConfig = thisScene.createLayer(thisScene.getInitialLayerConfig('background'));
                shared.copy = thisScene.createLayer(thisLayer);
                shared.text = thisScene.createLayer({ text: 'hi', origin: new Vec3(1, 2, 3), name: 'label' });
                shared.missing = thisScene.createLayer('models/missing.json');
            }
            """)
        f.runtime.load()
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(f.evaluate("shared.missing")?.isNull, true)
        XCTAssertEqual(f.evaluate("thisScene.getLayer(0) === shared.bar && thisScene.getLayerIndex('background') === 1")?
            .toBool(), true, "sortLayer applies at once")
        XCTAssertEqual(f.evaluate("shared.text instanceof __rt.objects.TextLayer")?.toBool(), true)
        XCTAssertEqual(f.table(5, .color), [0, 0, 1])
        XCTAssertEqual(f.table(5, .alpha), [0.5])

        f.runtime.frame(deltaTime: 1.0 / 60)
        let configJSON = #"{"id":1,"name":"background","image":"models/background.json","origin":"10 20 0"}"#
        XCTAssertEqual(f.host.takeCommands(), [
            .create(slot: 5, source: .asset("models/bar.json")),
            .sort(slot: 5, index: 0),
            .create(slot: 6, source: .configuration(json: configJSON)),
            .create(slot: 7, source: .copy(slot: 0)),
            .create(slot: 8, source: .configuration(json: #"{"text":"hi","origin":"1 2 3","name":"label"}"#)),
            .setString(slot: 5, field: .alignment, value: "center"),
        ])

        XCTAssertEqual(f.evaluate("thisScene.destroyLayer(shared.bar)")?.toBool(), true)
        XCTAssertEqual(f.evaluate("thisScene.destroyLayer('nope')")?.toBool(), false)
        XCTAssertEqual(f.evaluate("thisScene.getLayerCount()")?.toInt32(), 9, "removed only after the frame's updates")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [.destroy(slot: 5)])
        XCTAssertEqual(f.evaluate("thisScene.getLayerCount()")?.toInt32(), 8)
        XCTAssertFalse(f.store.isLive(5))
        XCTAssertEqual(f.evaluate("shared.bar.alpha = 0.9; shared.bar.alpha")?.toDouble(), 0.5,
                       "a destroyed layer keeps its last values and ignores writes")

        f.evaluate("shared.again = thisScene.createLayer('models/bar.json');")
        XCTAssertEqual(f.model.slot(forObjectID: 100), 5, "the freed slot is reused")
        XCTAssertEqual(f.evaluate("shared.bar.alpha + ',' + shared.again.alpha")?.toString(), "0.5,1")
    }

    func testDestroyingALayerDestroysItsChildrenAndTheirScripts() throws {
        let f = try fixture()
        f.add("clock-script", slot: 1, "function destroy() { shared.destroyed = thisLayer.name; }")
        f.runtime.load()
        f.evaluate("thisScene.destroyLayer('background')")
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(f.host.takeCommands(), [.destroy(slot: 0), .destroy(slot: 1)])
        XCTAssertEqual(f.evaluate("shared.destroyed")?.toString(), "clock")
        XCTAssertEqual(f.evaluate("thisScene.enumerateLayers().map(l => l.name).join()")?.toString(), "music,snow,group")
    }

    func testAFullTableMakesCreateLayerReturnNull() throws {
        var capacity = SceneScriptObjectStore.Capacity.standard
        capacity.objects = 6
        let f = try fixture(capacity: capacity)
        XCTAssertEqual(f.evaluate("thisScene.createLayer('models/bar.json') !== null")?.toBool(), true)
        XCTAssertEqual(f.evaluate("thisScene.createLayer('models/bar.json')")?.isNull, true)
    }

    // MARK: - Playback, animations, scene

    func testPlaybackAndAnimationCommands() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        f.evaluate("""
            var music = thisScene.getLayer('music'), snow = thisScene.getLayer('snow'), bg = thisScene.getLayer(0);
            music.play(); shared.playing = music.isPlaying(); music.volume = 0.25; music.stop();
            snow.emitParticles(5); snow.emitParticles(); snow.pause();
            snow.instance.rate = 2; snow.instance.controlpoint3 = new Vec3(1, 2, 3);
            var sprite = bg.getTextureAnimation();
            sprite.rate = 9; sprite.setFrame(1); sprite.stop(); sprite.join();
            shared.sprite = [sprite === bg.getTextureAnimation(), sprite.frameCount, sprite.duration, sprite.isPlaying(),
                             thisScene.getLayer('clock').getTextureAnimation()].join();
            bg.play(); bg.emitParticles(3);
            """)
        XCTAssertEqual(f.evaluate("shared.playing + ',' + music.isPlaying()")?.toString(), "true,false")
        XCTAssertEqual(f.evaluate("shared.sprite")?.toString(), "true,8,1,true,",
                       "join() returns to the shared clock, which plays; a text layer has no texture animation")
        XCTAssertEqual(f.table(2, .volume), [0.25])
        XCTAssertEqual(f.table(3, .instanceRate), [2])
        XCTAssertEqual(f.table(3, .controlpoint3), [1, 2, 3])
        XCTAssertEqual(f.table(3, .alpha), [1], "instance members are the particle system's own fields")
        XCTAssertEqual(f.store.animations[2, SceneScriptObjectStore.AnimationLayout.rate], 9, "the texture animation follows the effect animations")

        f.runtime.load()
        f.runtime.frame(deltaTime: 1.0 / 60)
        let commands = f.host.takeCommands()
        XCTAssertEqual(Array(commands.prefix(5)), [.sound(slot: 2, .play), .sound(slot: 2, .stop),
                                                   .emitParticles(slot: 3, count: 5), .emitParticles(slot: 3, count: nil),
                                                   .particles(slot: 3, .pause)])
        let actions = commands.dropFirst(5).compactMap { command -> SceneScriptObjectCommand.AnimationAction? in
            guard case .animation(let reference, let action) = command, reference.isTextureAnimation else { return nil }
            return action
        }
        XCTAssertEqual(actions, [.setFrame(1), .stop, .join])
        XCTAssertEqual(commands.count, 8, "image layers ignore sound and particle calls")
    }

    func testSceneSettingsAndCameraTransforms() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        XCTAssertEqual(f.evaluate("thisScene.bloomstrength")?.toDouble(), 2)
        f.evaluate("thisScene.bloomstrength = 3; thisScene.camerashake = true; thisScene.clearcolor = new Vec3(0.5);")
        let scene = f.store.scene
        XCTAssertEqual(scene[0, SceneScriptSceneField.bloomstrength.offset], 3)
        XCTAssertEqual(scene[0, SceneScriptSceneField.camerashake.offset], 1)
        XCTAssertEqual(scene.read(slot: 0, offset: SceneScriptSceneField.clearcolor.offset, count: 3), [0.5, 0.5, 0.5])
        XCTAssertEqual(scene.dirty[SceneScriptSceneField.Layout.settingsDirty], 1)
        XCTAssertEqual(scene.dirty[SceneScriptSceneField.Layout.cameraDirty], 0)

        f.evaluate("thisScene.setCameraTransforms({ eye: new Vec3(1, 2, 3), zoom: 2 });")
        XCTAssertEqual(f.evaluate("var c = thisScene.getCameraTransforms(); [c.eye.z, c.center.x, c.up.y, c.zoom].join()")?
            .toString(), "3,0,1,2")
        XCTAssertEqual(scene.dirty[SceneScriptSceneField.Layout.cameraDirty], 1)
        XCTAssertEqual(f.evaluate("'cameraEye' in thisScene")?.toBool(), false, "camera fields are not scene members")
    }

    /// A scene that leaves its `general` values out shows scripts the engine's defaults: bloom on at
    /// strength 2 and threshold 0.65 (the constructor's flags 0x26, 0x140186d1f), not 0.
    func testSceneSettingsDefaultToTheEnginesWhenTheSceneLeavesThemOut() throws {
        let host = FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: []))
        let f = try SceneScriptObjectFixture(host, capacity: .standard)
        XCTAssertEqual(f.evaluate("thisScene.bloom")?.toBool(), true)
        XCTAssertEqual(try XCTUnwrap(f.evaluate("thisScene.bloomstrength")?.toDouble()), 2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(f.evaluate("thisScene.bloomthreshold")?.toDouble()), 0.65, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(f.evaluate("thisScene.camerashakespeed")?.toDouble()), 3, accuracy: 1e-6)
    }

    /// Every scene field's script default is what the engine uses for a scene without it.
    func testSceneFieldDefaultsMatchTheEngines() throws {
        let json = #"{"camera":{},"general":{},"objects":[]}"#
        let general = try JSONDecoder().decode(WEScene.self, from: Data(json.utf8)).general
        let values = EmptyValues()
        let bloom = SceneBloomSettings(general, in: values)
        let effects = SceneCameraEffects(general, in: values)
        let camera = SceneCameraSettings(general, in: values)
        let lighting = SceneLightingSettings(general, in: values)
        var expected: [SceneScriptSceneField: [Float]] = [:]
        expected[.bloom] = [bloom.enabled ? 1 : 0]
        expected[.bloomstrength] = [bloom.strength]
        expected[.bloomthreshold] = [bloom.threshold]
        expected[.clearcolor] = Self.components(general.clearColor(in: values))
        expected[.ambientcolor] = Self.components(lighting.ambient)
        expected[.skylightcolor] = Self.components(lighting.skylight)
        expected[.fov] = [Float(camera.fov)]
        expected[.nearz] = [Float(camera.nearZ)]
        expected[.farz] = [Float(camera.farZ)]
        expected[.camerafade] = [camera.cameraFade ? 1 : 0]
        expected[.camerashake] = [effects.shake ? 1 : 0]
        expected[.camerashakespeed] = [effects.shakeSpeed]
        expected[.camerashakeamplitude] = [effects.shakeAmplitude]
        expected[.camerashakeroughness] = [effects.shakeRoughness]
        expected[.cameraparallax] = [effects.parallax ? 1 : 0]
        expected[.cameraparallaxamount] = [effects.parallaxAmount]
        expected[.cameraparallaxdelay] = [effects.parallaxDelay]
        expected[.cameraparallaxmouseinfluence] = [effects.parallaxMouseInfluence]
        expected[.bloomhdrstrength] = [bloom.hdr.strength]
        expected[.bloomhdrthreshold] = [bloom.hdr.threshold]
        expected[.bloomhdrfeather] = [bloom.hdr.feather]
        expected[.bloomhdrscatter] = [bloom.hdr.scatter]
        expected[.bloomhdriterations] = [Float(bloom.hdr.iterations)]
        for (field, value) in expected {
            XCTAssertEqual(field.defaultValue, value, "\(field.rawValue)")
        }
    }

    private struct EmptyValues: SceneValueContext {
        func userProperty(_ name: String) -> String? { nil }
    }

    private static func components(_ vector: SIMD3<Float>) -> [Float] { [vector.x, vector.y, vector.z] }

    func testLayerWithoutVideoOrRigAnswersAsWEDoes() throws {
        _ = try Fixtures.assets()
        let f = try fixture()
        XCTAssertEqual(f.evaluate("""
            var bg = thisScene.getLayer(0);
            [bg.getVideoTexture(), bg.resetBonePhysicsSimulation()].join()
            """)?.toString(), ",", "a picture has no video texture; a layer without a rig ignores bone physics")
        // A layer without a rig answers the bone and attachment API as WE does for one: nothing.
        XCTAssertEqual(f.evaluate("[bg.getBoneCount(), bg.getAnimationLayer(0), bg.getAttachmentMatrix('a') instanceof Mat4].join()")?
            .toString(), "0,,true")
    }

    // MARK: - Bindings

    func testBindingsFromSceneFieldPaths() {
        XCTAssertEqual(SceneScriptObjectBinding(fieldPath: "alpha", slot: 2), .layer(slot: 2, property: "alpha"))
        XCTAssertEqual(SceneScriptObjectBinding(fieldPath: "instanceoverride.rate", slot: 2),
                       .layer(slot: 2, property: "instanceoverride.rate"))
        XCTAssertEqual(SceneScriptObjectBinding(fieldPath: "effects.1.visible", slot: 2),
                       .effect(slot: 2, effect: 1, property: "visible"))
        XCTAssertEqual(SceneScriptObjectBinding(fieldPath: "effects.0.passes.1.constantshadervalues.Bar Color", slot: 2),
                       .material(slot: 2, effect: 0, material: 1, constant: "Bar Color"))
        XCTAssertEqual(SceneScriptObjectBinding(fieldPath: "general.bloomstrength", slot: nil),
                       .scene(property: "bloomstrength"))
        XCTAssertNil(SceneScriptObjectBinding(fieldPath: "effects.x.visible", slot: 2))
        XCTAssertNil(SceneScriptObjectBinding(fieldPath: "alpha", slot: nil))
    }
}
