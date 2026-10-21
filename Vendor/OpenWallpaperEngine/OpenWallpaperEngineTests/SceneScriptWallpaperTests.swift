import XCTest
import simd
@testable import OpenWallpaperEngine

/// `SceneScriptWallpaper` without a renderer (docs/scenescript-plan.md WP11): what the renderer
/// feeds in reaches the scripts, and what scripts write comes back as state and events.
final class SceneScriptWallpaperTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-wallpaper-scripts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    // MARK: - State

    /// Only the fields a script writes become the table's; the others stay the renderer's, and
    /// scripts read the renderer's live values (§1.9 P2).
    func testScriptsOwnWhatTheyWriteAndReadTheRenderersValues() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""origin": {"script": "export function update(value) { shared.seen = thisLayer.scale.x; value.y = 7; return value; }", "value": "10 20 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        input.objects[1] = feedback(origin: SIMD2(10, 20), scale: SIMD2(3, 3))
        let state = try frame(wallpaper, input)

        let layer = try XCTUnwrap(state.objects[1])
        XCTAssertEqual(layer.vector3(.origin), SIMD3(10, 7, 0))
        XCTAssertNil(layer.vector3(.scale), "scale was only read")
        XCTAssertNil(layer.scalar(.alpha))
        XCTAssertEqual(try shared(wallpaper, "seen"), 3, "the script read the renderer's scale")
    }

    /// An animated field a script owns still gets the animation's value before each frame: the
    /// script's `update(value)` starts from it (§1.9 P2, test-risks S7).
    func testAnAnimatedFieldTheScriptOwnsStartsFromTheAnimation() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""alpha": {"script": "export function update(value) { return value + 0.25; }", "value": 1}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var animated = feedback(origin: .zero, scale: SIMD2(1, 1))
        animated.alpha = 0.5
        animated.animated.insert(.alpha)
        input.objects[1] = animated
        _ = try frame(wallpaper, input)
        let state = try frame(wallpaper, input)
        XCTAssertEqual(try XCTUnwrap(state.objects[1]?.scalar(.alpha)), 0.75, accuracy: 1e-6,
                       "the animated 0.5 plus this frame's increment, not an accumulation")
    }

    func testWorldMatricesReachGetTransformMatrix() throws {
        _ = try Fixtures.assets()
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""origin": {"script": "export function update(value) { shared.tx = thisLayer.getTransformMatrix().translation().x; return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var moved = feedback(origin: .zero, scale: SIMD2(1, 1))
        moved.world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(123, 4))
        input.objects[1] = moved
        _ = try frame(wallpaper, input)
        XCTAssertEqual(try shared(wallpaper, "tx"), 123)
    }

    // MARK: - Structure

    func testCreateSortAndDestroyBecomeEventsAndOrder() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json""#),
            object(id: 2, fields: #""origin": {"script": "let made; export function update(value) { if (!made) { made = thisScene.createLayer({ image: 'models/b.json', origin: '5 6 0' }); thisScene.sortLayer(made, 0); } else if (!shared.gone) { thisScene.destroyLayer(made); shared.gone = true; } return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        var taken = wallpaper.take()
        guard case .create(let id, let json)? = taken.events.first else { return XCTFail("no create: \(taken.events)") }
        XCTAssertEqual(json["image"], .string("models/b.json"))
        XCTAssertEqual(taken.state?.order, [id, 1, 2], "sortLayer(made, 0) put it at the bottom")

        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        taken = wallpaper.take()
        guard case .destroy(let destroyed)? = taken.events.first else { return XCTFail("no destroy: \(taken.events)") }
        XCTAssertEqual(destroyed, id)
        XCTAssertEqual(taken.state?.order, [1, 2])
    }

    /// WP4-C: what `createLayer` made is built on the script thread with the frame, so the renderer
    /// takes it with that frame's events and draws it in the same frame, as WE does.
    func testACreatedLayerIsPreparedWithTheFrameThatMadeIt() throws {
        let sound = SceneSoundContent(id: 0, name: "made", sound: WESceneSound(files: ["sounds/tone.wav"], playbackMode: .loop),
                                      files: [], volume: 1)
        let script = "let made; export function update(value) { if (!made) made = thisScene.createLayer({ sound: ['sounds/tone.wav'] }); return value; }"
        var preparedOnScriptThread = false
        let wallpaper = try make(objects: [object(id: 1, fields: #""origin": {"script": "\#(script)", "value": "0 0 0"}"#)],
                                 makeLayer: { _ in .sound(sound) },
                                 prepareCreated: { created, id in
                                     preparedOnScriptThread = !Thread.isMainThread
                                     guard case .sound = created else { return nil }
                                     return id
                                 })
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        XCTAssertTrue(wallpaper.waitForSubmittedFrame(timeout: 5))
        let taken = wallpaper.take()
        guard case .create(let id, _)? = taken.events.first else { return XCTFail("no create: \(taken.events)") }
        XCTAssertEqual(wallpaper.takePrepared(id) as? Int, id, "built before the frame was published")
        XCTAssertTrue(preparedOnScriptThread)
        XCTAssertNil(wallpaper.takePrepared(id), "taken once")
    }

    /// `ILayer.setParent` reaches the renderer as a render event with scene ids, and `getParent`
    /// answers the new parent at once.
    func testSetParentBecomesARenderEvent() throws {
        let script = "export function update(value) { if (shared.done) return value; shared.done = true; "
            + "thisLayer.setParent(2); shared.parent = thisLayer.getParent().id; thisScene.getLayer('Object 2').setParent(); "
            + "return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #""origin": {"script": "\#(script)", "value": "0 0 0"}"#),
                                           object(id: 2, fields: #""parent": 3"#), object(id: 3, fields: #""origin": "0 0 0""#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        let events = wallpaper.take().events.compactMap { event -> String? in
            guard case let .setParent(id, parentID, attachment) = event else { return nil }
            return "\(id)>\(parentID.map(String.init) ?? "nil")\(attachment.map { "@" + $0 } ?? "")"
        }
        XCTAssertEqual(events, ["1>2", "2>nil"])
        XCTAssertEqual(try shared(wallpaper, "parent"), 2)
    }

    /// `IEffect.executeMaterialFunction(name)` reaches the renderer as a render event with the
    /// object's scene id, the effect's index and the name, once per call.
    func testExecuteMaterialFunctionBecomesARenderEvent() throws {
        let script = "export function update(value) { if (shared.done) return value; shared.done = true; "
            + "thisLayer.getEffect(0).executeMaterialFunction('clearDye'); return value; }"
        let effects = #""effects": [{"file": "effects/fluidsimulation/effect.json", "name": "fluid", "passes": [{}]}]"#
        let wallpaper = try make(objects: [object(id: 4, fields: #""origin": {"script": "\#(script)", "value": "0 0 0"}, "#
                                                  + effects)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        for _ in 0..<2 {
            wallpaper.submit(input)
            wallpaper.waitUntilIdle()
        }
        let calls = wallpaper.take().events.compactMap { event -> String? in
            guard case let .materialFunction(id, effect, name) = event else { return nil }
            return "\(id).\(effect).\(name)"
        }
        XCTAssertEqual(calls, ["4.0.clearDye"])
    }

    /// test-risks S11's clone stress test: a layer created and destroyed every frame for 1000
    /// frames leaves the scene as it was (every create has its destroy; slots are reused).
    func testCreatingAndDestroyingALayerEveryFrameStaysFlat() throws {
        // `destroyLayer` applies after the frame's updates, so the count is read first.
        let churn = "let made = null; export function update(value) { shared.count = thisScene.getLayerCount(); "
            + "if (made !== null) thisScene.destroyLayer(made); made = thisScene.createLayer({ image: 'models/b.json' }); return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #""origin": {"script": "\#(churn)", "value": "0 0 0"}"#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var created = Set<Int>(), destroyed = Set<Int>()
        for _ in 0..<1000 {
            wallpaper.submit(input)
            wallpaper.waitUntilIdle()
            for event in wallpaper.take().events {
                switch event {
                case .create(let id, _): created.insert(id)
                case .destroy(let id): destroyed.insert(id)
                case .emit, .materialFunction, .sound, .animation, .textureAnimation, .rig, .setParent, .video: break
                }
            }
        }
        XCTAssertEqual(created.count, 1000)
        XCTAssertEqual(destroyed.count, 999, "all but the last one")
        XCTAssertEqual(try shared(wallpaper, "count"), 2, "the scene holds its object and one made layer")
        let slots = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("__rt.objects.bySlot.size")?.toInt32() }
        XCTAssertEqual(slots, 2, "destroyed layers' slots are free again")
    }

    /// Scripts read a timeline as the renderer's set left it this frame (the clocks advance before
    /// them, §1.9 P1), and what their `IAnimation` calls did comes back as a render event the
    /// renderer restores before its next advance (docs/timeline-plan.md §3.1).
    func testIAnimationStateGoesInAndCallsComeBack() throws {
        let alpha = #""alpha": {"value": 1, "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 20, "value": 1}], "options": {"fps": 10, "length": 20, "name": "fade"}}}"#
        let script = "export function update(value) { if (shared.done) return value; shared.done = true; "
            + "const a = thisLayer.getAnimation('fade'); shared.before = a.getFrame(); "
            + "shared.playing = a.isPlaying() ? 1 : 0; a.pause(); a.setFrame(5); a.rate = 2; return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #"\#(alpha), "origin": {"script": "\#(script)", "value": "0 0 0"}"#)])
        let site = SceneAnimationSite(owner: .object(1), key: "alpha")
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        input.animations[site] = SceneAnimationState(name: "fade", fps: 10, frameCount: 20, duration: 2, rate: 1,
                                                     time: 0.3, flags: [], frame: 3)
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        let events = wallpaper.take().events
        XCTAssertEqual(try shared(wallpaper, "before"), 3, "getFrame() is the set's frame")
        XCTAssertEqual(try shared(wallpaper, "playing"), 1)
        let restores = events.compactMap { event -> (SceneAnimationSite, Float, SceneTimelineClock.Flags, Float)? in
            guard case let .animation(site, time, flags, rate, _) = event else { return nil }
            return (site, time, flags, rate)
        }
        XCTAssertEqual(restores.count, 1, "\(events)")
        XCTAssertEqual(restores.first?.0, site)
        XCTAssertEqual(try XCTUnwrap(restores.first?.1), 0.5, accuracy: 1e-6, "frame 5 at 10 fps")
        XCTAssertEqual(restores.first?.2, [.paused])
        XCTAssertEqual(restores.first?.3, 2)

        // A frame without calls sends nothing back.
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        XCTAssertFalse(wallpaper.take().events.contains { if case .animation = $0 { return true } else { return false } })
    }

    /// 2321732083 flies its cars with `ship.getAnimation('origin').play()` on `origin` timelines
    /// that have no `options.name` and start paused: the property's key finds such a timeline, and
    /// the play comes back as that timeline running. A timeline's name still wins over a key.
    func testGetAnimationFindsAnUnnamedTimelineByItsPropertyAndPlaysIt() throws {
        let keys = #"[{"frame": 0, "value": 0}, {"frame": 30, "value": 100}]"#
        let origin = #""origin": {"value": "0 0 0", "animation": {"c0": \#(keys), "c1": \#(keys), "c2": \#(keys), "#
            + #""options": {"fps": 6, "length": 30, "mode": "single", "startpaused": true}}}"#
        let alpha = #""alpha": {"value": 1, "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 30, "value": 1}], "#
            + #""options": {"fps": 6, "length": 30, "name": "origin"}}}"#
        let script = "export function update(value) { if (shared.done) return value; shared.done = true; "
            + "const ship = thisScene.getLayer('Object 1'), a = ship.getAnimation('origin'); "
            + "shared.found = a ? 1 : 0; shared.fps = a.fps; shared.before = a.isPlaying() ? 1 : 0; a.play(); "
            + "shared.after = a.isPlaying() ? 1 : 0; shared.named = thisScene.getLayer('Object 3').getAnimation('origin').fps; "
            + "shared.none = ship.getAnimation('scale') === null ? 1 : 0; return value; }"
        let wallpaper = try make(objects: [
            object(id: 1, fields: origin),
            object(id: 2, fields: #""origin": {"script": "\#(script)", "value": "0 0 0"}"#),
            object(id: 3, fields: "\(origin.replacingOccurrences(of: #""fps": 6"#, with: #""fps": 12"#)), \(alpha)"),
        ])
        let site = SceneAnimationSite(owner: .object(1), key: "origin")
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        input.animations[site] = SceneAnimationState(name: nil, fps: 6, frameCount: 30, duration: 5, rate: 1,
                                                     time: 0, flags: [.paused], frame: 0)
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        let events = wallpaper.take().events
        XCTAssertEqual(try shared(wallpaper, "found"), 1, "getAnimation('origin') finds the unnamed origin timeline")
        XCTAssertEqual(try XCTUnwrap(try shared(wallpaper, "fps")), 6, accuracy: 1e-4)
        XCTAssertEqual(try shared(wallpaper, "before"), 0, "it starts paused")
        XCTAssertEqual(try shared(wallpaper, "after"), 1)
        XCTAssertEqual(try XCTUnwrap(try shared(wallpaper, "named")), 6, accuracy: 1e-4,
                       "the alpha timeline named 'origin' wins over the origin property's (12 fps)")
        XCTAssertEqual(try shared(wallpaper, "none"), 1, "a property without a timeline has no animation")
        let restores = events.compactMap { event -> (SceneAnimationSite, SceneTimelineClock.Flags)? in
            guard case let .animation(site, _, flags, _, _) = event else { return nil }
            return (site, flags)
        }
        XCTAssertEqual(restores.map(\.0), [site], "\(events)")
        XCTAssertEqual(restores.first?.1, [], "play() leaves it running")
    }

    /// §2.6 for the scene's settings (TF3): a script bound to an animated `general` value gets
    /// this frame's animated value, and its different return holds for that frame only.
    func testScriptsSeeAnimatedSceneSettingsAndBeatThemForTheirFrameOnly() throws {
        let script = "export function update(value) { shared.seen = value; return shared.override ? 9 : value; }"
        let bloom = #""bloomstrength": {"value": 1, "script": "\#(script)", "animation": {"c0": [{"frame": 0, "value": 0}, {"frame": 20, "value": 2}], "options": {"fps": 10, "length": 20}}}"#
        let wallpaper = try make(objects: [], general: bloom)
        let site = SceneAnimationSite(owner: .scene, key: "bloomstrength")
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        for (value, override, drawn) in [(Float(0.5), false, Float?.none), (0.75, true, 9), (1, false, nil)] {
            input.animations[site] = SceneAnimationState(name: nil, fps: 10, frameCount: 20, duration: 2, rate: 1, time: 0,
                                                         flags: [], frame: 0, value: SIMD4(value, 0, 0, 0))
            wallpaper.thread.sync { _ = wallpaper.scriptRuntime?.context.evaluateScript("shared.override = \(override)") }
            let state = try frame(wallpaper, input)
            XCTAssertEqual(try shared(wallpaper, "seen"), Double(value), "update(value) gets the animated value")
            XCTAssertEqual(state.scene.scalar(.bloomstrength), drawn, "the script's value only while it differs")
        }
    }

    /// A timeline event reaches `animationEvent` of the scripts attached to the animation's owner,
    /// before `update` in the same frame (§3.3, P1).
    func testTimelineEventsReachTheOwnersScripts() throws {
        let alpha = #""alpha": {"value": 1, "animation": {"c0": [{"frame": 0, "value": 0}], "options": {"fps": 10, "length": 20, "events": [{"name": "hit", "frame": 4}]}}}"#
        let script = "shared.log = ''; export function animationEvent(event, value) { shared.log += event.name + '@' + event.frame + ';'; return value; } "
            + "export function update(value) { shared.log += 'u;'; return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #"\#(alpha), "origin": {"script": "\#(script)", "value": "0 0 0"}"#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        input.animationEvents = [SceneAnimationEvent(site: SceneAnimationSite(owner: .object(1), key: "alpha"), name: "hit", frame: 4),
                                 SceneAnimationEvent(site: SceneAnimationSite(owner: .object(9), key: "alpha"), name: "nobody", frame: 1)]
        _ = try frame(wallpaper, input)
        let log = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.log")?.toString() }
        XCTAssertEqual(log, "hit@4;u;")
    }

    /// `engine.isObjectValid` (undocumented, in scenescript64.dll): false once a layer is destroyed.
    func testIsObjectValidFollowsDestroyLayer() throws {
        let script = "let made; export function update(value) { if (!made) { made = thisScene.createLayer({ image: 'models/b.json' }); "
            + "shared.before = engine.isObjectValid(made) ? 1 : 0; thisScene.destroyLayer(made); } "
            + "else { shared.after = engine.isObjectValid(made) ? 1 : 0; shared.self = engine.isObjectValid(thisLayer) ? 1 : 0; } return value; }"
        let wallpaper = try make(objects: [object(id: 1, fields: #""origin": {"script": "\#(script)", "value": "0 0 0"}"#)])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        _ = try frame(wallpaper, input)
        _ = try frame(wallpaper, input)
        XCTAssertEqual(try shared(wallpaper, "before"), 1)
        XCTAssertEqual(try shared(wallpaper, "after"), 0)
        XCTAssertEqual(try shared(wallpaper, "self"), 1)
    }

    func testEffectVisibilityAndMaterialConstantsComeBack() throws {
        _ = try Fixtures.assets()
        let effect = #"{"file": "effects/tint/effect.json", "visible": false, "passes": [{"constantshadervalues": {"color": "0 0 1"}}]}"#
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json", "effects": [\#(effect)], "origin": {"script": "export function update(value) { const e = thisLayer.getEffect(0); e.visible = true; e.setMaterialProperty('color', new Vec3(0, 1, 0)); return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        let state = try frame(wallpaper, input)
        let layer = try XCTUnwrap(state.objects[1])
        XCTAssertEqual(layer.effectVisible[0], true)
        XCTAssertEqual(layer.constants[0], [SceneScriptConstantWrite(material: nil, name: "color", value: [0, 1, 0])])
        XCTAssertGreaterThan(layer.effectRevision, 0)
    }

    /// A text script's string and a scene setting come back; a particle system's playback too.
    func testStringsSceneSettingsAndPlayback() throws {
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""text": {"script": "export function update() { return 'hello'; }", "value": ""}"#),
            object(id: 2, fields: #""particle": "particles/p.json", "origin": {"script": "export function update(value) { thisLayer.pause(); thisScene.camerashake = true; return value; }", "value": "0 0 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        let state = try frame(wallpaper, input)
        XCTAssertEqual(state.objects[1]?.strings[.text], "hello")
        XCTAssertEqual(state.objects[2]?.playback, .pause)
        XCTAssertEqual(state.scene.flag(.camerashake), true)
        XCTAssertNil(state.scene.flag(.bloom), "untouched settings stay the scene's")
    }

    /// WP10: the renderer's cursor frame reaches only the hit object's scripts.
    func testTheCursorPassClicksTheLayerUnderTheCursor() throws {
        _ = try Fixtures.assets()
        let clicker = #"export function cursorClick() { shared.clicks = (shared.clicks || 0) + 1; }"#
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json", "size": "100 100", "origin": {"script": "\#(clicker) export function update(value) { return value; }", "value": "50 50 0"}"#),
        ])
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var layer = feedback(origin: SIMD2(50, 50), scale: SIMD2(1, 1))
        layer.world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(50, 50))
        layer.size = SIMD2(100, 100)
        input.objects[1] = layer
        input.cursorScenePosition = SIMD2(60, 40)
        for down in [false, true, false] {
            input.input.cursorLeftDown = down
            _ = try frame(wallpaper, input)
        }
        _ = try frame(wallpaper, input)
        XCTAssertEqual(try shared(wallpaper, "clicks"), 1)
    }

    /// `engine.openUserShortcut` in a click opens the user's binding of the property through the
    /// app's launcher and returns true; a property only project.json "binds" opens nothing.
    func testAClickOpensTheUserShortcutTheUserBound() throws {
        _ = try Fixtures.assets()
        let project = try SceneScriptSiteBuilder.document(from: Data(#"""
            {"general": {"properties": {
             "mine": {"type": "usershortcut", "text": "Mine"},
             "authored": {"type": "usershortcut", "text": "Authored", "value": "cmd:a1b2c3:say authored", "isbound": true}}}}
            """#.utf8))
        let opener = RecordingUserShortcutOpener()
        let clicker = #"export function cursorClick() { shared.authored = engine.openUserShortcut('authored') ? 1 : 0; shared.mine = engine.openUserShortcut('mine'); }"#
        let wallpaper = try make(objects: [
            object(id: 1, fields: #""image": "models/a.json", "size": "100 100", "origin": {"script": "\#(clicker) export function update(value) { return value; }", "value": "50 50 0"}"#),
        ], project: project, userValues: ["mine": "web:a1b2c3:https://example.com"],
           userShortcuts: UserShortcutLauncher(opener: opener, systemHash: "a1b2c3"))
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        var layer = feedback(origin: SIMD2(50, 50), scale: SIMD2(1, 1))
        layer.world = SceneAffineTransform(linear: matrix_identity_float2x2, translation: SIMD2(50, 50))
        layer.size = SIMD2(100, 100)
        input.objects[1] = layer
        input.cursorScenePosition = SIMD2(60, 40)
        for down in [false, true, false] {
            input.input.cursorLeftDown = down
            _ = try frame(wallpaper, input)
        }
        _ = try frame(wallpaper, input)
        let opened: Bool? = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.mine")?.toBool() }
        XCTAssertEqual(opened, true)
        XCTAssertEqual(opener.calls, ["web https://example.com"], "the authored shortcut opened nothing")
        XCTAssertEqual(try shared(wallpaper, "authored"), 0, "false, so the click could still open one")
    }

    /// The user's values reach `engine.userProperties` in WE's raw form, typed as project.json declares.
    func testUserPropertiesKeepTheirDeclaredTypes() throws {
        var properties = SceneScriptUserProperties(project: try SceneScriptSiteBuilder.document(from: Data(#"""
            {"general": {"properties": {"on": {"type": "bool", "value": false}, "speed": {"type": "slider", "value": 1},
             "mode": {"type": "combo", "value": 2}, "tint": {"type": "color", "value": "1 0 0"}}}}
            """#.utf8)))
        properties.setStoredValues(["on": "true", "speed": "0.5", "mode": "3", "tint": "0 1 0"])
        XCTAssertEqual(properties.value(of: "on"), .bool(true))
        XCTAssertEqual(properties.value(of: "speed"), .number(0.5))
        XCTAssertEqual(properties.value(of: "mode"), .number(3))
        XCTAssertEqual(properties.value(of: "tint"), .string("0 1 0"))
    }

    // MARK: - Support

    private func object(id: Int, fields: String) -> String {
        #"{"id": \#(id), "name": "Object \#(id)", \#(fields)}"#
    }

    private func make(objects: [String], general: String = "", project: SceneJSON? = nil,
                      userValues: [String: String] = [:], userShortcuts: UserShortcutLauncher? = nil,
                      makeLayer: @escaping ([String: SceneJSON]) -> SceneScriptCreatedObject? = { _ in nil },
                      prepareCreated: SceneScriptWallpaper.PrepareCreated? = nil) throws -> SceneScriptWallpaper {
        let settings = general.isEmpty ? "" : ", " + general
        let text = #"{"general": {"orthogonalprojection": {"width": 200, "height": 100}\#(settings)}, "objects": [\#(objects.joined(separator: ", "))]}"#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "test-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: project, userValues: { userValues },
                                              file: { _ in nil }, makeLayer: makeLayer)
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent },
                                           userShortcuts: userShortcuts)
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test",
                                                                  prepareCreated: prepareCreated))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        return wallpaper
    }

    private func feedback(origin: SIMD2<Float>, scale: SIMD2<Float>) -> SceneScriptObjectFeedback {
        SceneScriptObjectFeedback(origin: origin, scale: scale, angle: 0, alpha: nil, color: nil, visible: true, size: nil,
                                  world: SceneAffineTransform(SceneLocalTransform(origin: origin, scale: scale, angle: 0)))
    }

    /// Runs one script frame and returns the state it left.
    private func frame(_ wallpaper: SceneScriptWallpaper, _ input: SceneScriptFrameInput) throws -> SceneScriptFrameState {
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        return try XCTUnwrap(wallpaper.take().state)
    }

    private func shared(_ wallpaper: SceneScriptWallpaper, _ key: String) throws -> Double? {
        wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.\(key)")?.toDouble() }
    }
}
