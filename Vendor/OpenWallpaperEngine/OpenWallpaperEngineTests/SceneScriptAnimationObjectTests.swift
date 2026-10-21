import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// `IAnimation`, `ITextureAnimation` and `animationEvent` as scripts see them
/// (`objects-animations.js`, docs/timeline-plan.md §3), over the fake object host. The renderer's
/// side is played by writing the animation buffer, or by `SceneTextureAnimationControl`.
final class SceneScriptAnimationObjectTests: XCTestCase {
    private typealias Layout = SceneScriptObjectStore.AnimationLayout
    private typealias Flags = SceneScriptObjectStore.AnimationFlags

    private static func scene() -> SceneScriptSceneDescription {
        let tint = SceneScriptObjectDescription.Effect(
            name: "tint", visible: true,
            materials: [.init(constants: [.init(name: "multiply", value: [1])],
                              animations: [.init(name: "fade", fps: 15, frameCount: 30, duration: 2, property: "multiply")])])
        let sprite = SceneScriptObjectDescription.make(
            .image, id: 1, name: "sprite", values: [.alpha: [1]], effects: [tint],
            animations: [.init(name: "bounce", fps: 30, frameCount: 90, duration: 3, playing: true, property: "alpha"),
                         .init(name: "intro", fps: 30, frameCount: 60, duration: 2, playing: false, property: "origin")],
            textureAnimation: .init(name: "", fps: 1 / 0.03, frameCount: 147, duration: 4.41, playing: true))
        let other = SceneScriptObjectDescription.make(.image, id: 2, name: "other", values: [.alpha: [1]])
        return SceneScriptSceneDescription(objects: [sprite, other])
    }

    private func fixture() throws -> SceneScriptObjectFixture {
        let f = try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: Self.scene()),
                                             compiler: AllCallbacksTestSceneScriptCompiler())
        f.evaluate("""
            var sprite = thisScene.getLayer('sprite'), bounce = sprite.getAnimation('bounce'),
                intro = sprite.getAnimation('intro'), texture = sprite.getTextureAnimation();
            """)
        return f
    }

    private func slot(_ f: SceneScriptObjectFixture, _ expression: String) throws -> Int {
        Int(try XCTUnwrap(f.evaluate("\(expression)._record.slot")?.toInt32()))
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? {
        f.evaluate(script)?.toString()
    }

    // MARK: - IAnimation

    /// `thisScene.getAnimation(name)` finds a timeline of any owner: a layer's field, a material's
    /// constant; the same object the owner's own `getAnimation` gives. Only a string name is
    /// looked up (null otherwise), and a name nobody has gives undefined (scenescript64.dll
    /// 0x181635ee0 → 0x18163613d).
    func testTheSceneFindsAnAnimationOfAnyOwner() throws {
        let f = try fixture()
        XCTAssertEqual(string(f, "thisScene.getAnimation('bounce') === bounce"), "true")
        XCTAssertEqual(string(f, "thisScene.getAnimation('intro') === intro"), "true")
        XCTAssertEqual(string(f, "thisScene.getAnimation('fade') === sprite.getEffect(0).getMaterial(0).getAnimation('fade')"),
                       "true")
        XCTAssertEqual(string(f, "thisScene.getAnimation('fade').frameCount"), "30")
        XCTAssertEqual(string(f, "String(thisScene.getAnimation('nothing'))"), "undefined")
        XCTAssertEqual(string(f, "[thisScene.getAnimation(), thisScene.getAnimation(3), thisScene.getAnimation(new String('fade'))].join('|')"),
                       "||", "null for anything but a string")
        XCTAssertEqual(string(f, "String(thisScene.getAnimation())"), "null")
    }

    func testIsPlayingReadsThePausedAndFinishedFlags() throws {
        let f = try fixture()
        let bounce = try slot(f, "bounce")
        XCTAssertEqual(string(f, "[bounce.isPlaying(), intro.isPlaying()].join()"), "true,false", "startpaused is paused")
        f.store.animations[bounce, Layout.flags] = Float(Flags.finished)
        XCTAssertEqual(string(f, "bounce.isPlaying()"), "false", "a finished single isn't playing")
        f.store.animations[bounce, Layout.flags] = Float(Flags.backwards)
        XCTAssertEqual(string(f, "bounce.isPlaying()"), "true", "a mirror running backwards plays")
    }

    func testPlayRestartsAFinishedAnimationAndKeepsTheDirection() throws {
        let f = try fixture()
        let bounce = try slot(f, "bounce")
        // Where the renderer left a finished single: at its end.
        f.store.animations[bounce, Layout.time] = 3
        f.store.animations[bounce, Layout.frame] = 90
        f.store.animations[bounce, Layout.flags] = Float(Flags.finished | Flags.paused)
        f.evaluate("bounce.play()")
        XCTAssertEqual(string(f, "[bounce.isPlaying(), bounce.getFrame()].join()"), "true,0")
        XCTAssertEqual(f.store.animations[bounce, Layout.time], 0)
        XCTAssertEqual(f.store.animations[bounce, Layout.playing], 1)
        XCTAssertEqual(f.store.animations.dirty[bounce], 1, "the renderer reads the slot back")

        f.store.animations[bounce, Layout.time] = 1
        f.store.animations[bounce, Layout.frame] = 30
        f.store.animations[bounce, Layout.flags] = Float(Flags.paused | Flags.backwards)
        f.evaluate("bounce.play()")
        XCTAssertEqual(f.store.animations[bounce, Layout.flags], Float(Flags.backwards), "play keeps a mirror's direction")
        XCTAssertEqual(string(f, "bounce.getFrame()"), "30", "an unfinished animation resumes where it is")
    }

    func testPauseAndStop() throws {
        let f = try fixture()
        let bounce = try slot(f, "bounce")
        f.store.animations[bounce, Layout.time] = 1
        f.store.animations[bounce, Layout.frame] = 30
        f.evaluate("bounce.pause()")
        XCTAssertEqual(string(f, "[bounce.isPlaying(), bounce.getFrame()].join()"), "false,30", "pause holds the frame")
        f.store.animations[bounce, Layout.flags] = Float(Flags.paused | Flags.finished | Flags.backwards)
        f.evaluate("bounce.stop()")
        XCTAssertEqual(f.store.animations[bounce, Layout.flags], Float(Flags.paused), "stop clears finished and backwards")
        XCTAssertEqual(string(f, "[bounce.isPlaying(), bounce.getFrame()].join()"), "false,0")
        XCTAssertEqual(f.store.animations[bounce, Layout.time], 0)
    }

    func testSetFrameIsFractionalUnclampedAndKeepsThePlayState() throws {
        let f = try fixture()
        let bounce = try slot(f, "bounce")
        let frameDuration = Float(1) / Float(30)
        f.evaluate("bounce.setFrame(2.5)")
        XCTAssertEqual(f.store.animations[bounce, Layout.time], 2.5 * frameDuration)
        XCTAssertEqual(f.evaluate("bounce.getFrame()")?.toDouble() ?? 0, 2.5, accuracy: 1e-5)
        f.evaluate("bounce.setFrame(500)")
        XCTAssertEqual(f.evaluate("bounce.getFrame()")?.toDouble() ?? 0, 500, accuracy: 1e-3, "past the 90 frames")
        XCTAssertEqual(string(f, "bounce.isPlaying()"), "true")

        f.store.animations[bounce, Layout.flags] = Float(Flags.finished)
        f.evaluate("bounce.setFrame(3)")
        XCTAssertEqual(string(f, "bounce.isPlaying()"), "false", "a finished single stays finished")
        f.evaluate("bounce.play()")
        XCTAssertEqual(string(f, "bounce.getFrame()"), "0", "and play() restarts it from 0")
        f.evaluate("bounce.setFrame('7'); bounce.setFrame()")
        XCTAssertEqual(string(f, "bounce.getFrame()"), "0", "non-numbers are ignored")
    }

    func testRateFpsAndTheReadOnlyMembers() throws {
        let f = try fixture()
        let bounce = try slot(f, "bounce")
        f.evaluate("bounce.rate = -2.5; bounce.rate = 'fast'; bounce.fps = 1; bounce.frameCount = 1; bounce.name = 'x'")
        XCTAssertEqual(f.store.animations[bounce, Layout.rate], -2.5, "any number; a negative one runs backwards")
        XCTAssertEqual(f.evaluate("bounce.fps")?.toDouble(), Double(Float(1) / (Float(1) / Float(30))), "1 / (1/fps) in float")
        XCTAssertEqual(string(f, "[bounce.frameCount, bounce.duration, bounce.name].join()"), "90,3,bounce")
    }

    func testTheCommandsStillReachTheHost() throws {
        let f = try fixture()
        f.evaluate("bounce.play(); bounce.pause(); bounce.setFrame(4); bounce.stop()")
        f.runtime.load()
        f.runtime.frame(deltaTime: 1.0 / 60)
        let actions = f.host.takeCommands().compactMap { command -> SceneScriptObjectCommand.AnimationAction? in
            guard case .animation(let reference, let action) = command, reference.name == "bounce" else { return nil }
            return action
        }
        XCTAssertEqual(actions, [.play, .pause, .setFrame(4), .stop])
    }

    // MARK: - ITextureAnimation

    func testTheSharedClockUntilAScriptTakesControl() throws {
        let f = try fixture()
        let texture = try slot(f, "texture")
        f.store.animations[texture, Layout.sharedFrame] = 12
        f.store.animations[texture, Layout.sharedTime] = 0.01
        XCTAssertEqual(string(f, "[texture.isPlaying(), texture.getFrame(), texture.rate].join()"), "true,12,1")
        f.evaluate("texture.rate = 1; texture.play()")
        XCTAssertEqual(f.store.animations[texture, Layout.flags], 0, "rate 1 and play() don't take control")

        f.evaluate("texture.rate = 5")
        XCTAssertEqual(f.store.animations[texture, Layout.flags], Float(Flags.overridden))
        XCTAssertEqual(f.store.animations[texture, Layout.frame], 12, "the shared frame is copied")
        XCTAssertEqual(f.store.animations[texture, Layout.time], 0.01)
        f.store.animations[texture, Layout.sharedFrame] = 13
        f.evaluate("texture.rate = 0")
        XCTAssertEqual(string(f, "texture.getFrame()"), "12", "in control: the override's frame, copied once")
        XCTAssertEqual(string(f, "texture.isPlaying()"), "true")
    }

    func testANaNRateTakesControl() throws {
        let f = try fixture()
        let texture = try slot(f, "texture")
        f.evaluate("texture.rate = NaN")
        XCTAssertEqual(f.store.animations[texture, Layout.flags], Float(Flags.overridden))
    }

    func testPauseStopSetFrameAndJoin() throws {
        let f = try fixture()
        let texture = try slot(f, "texture")
        f.store.animations[texture, Layout.sharedFrame] = 4
        f.evaluate("texture.pause()")
        XCTAssertEqual(string(f, "[texture.isPlaying(), texture.getFrame()].join()"), "false,4")
        f.evaluate("texture.join()")
        XCTAssertEqual(string(f, "texture.isPlaying()"), "true", "joined: the shared clock always plays")
        XCTAssertEqual(f.store.animations[texture, Layout.playing], 0, "join keeps the override's playing flag")
        f.evaluate("texture.rate = 2")
        XCTAssertEqual(string(f, "texture.isPlaying()"), "false", "so taking control again doesn't play")

        f.evaluate("texture.join(); texture.play(); texture.stop()")
        XCTAssertEqual(string(f, "[texture.isPlaying(), texture.getFrame()].join()"), "false,0")
        f.evaluate("texture.setFrame(9.7)")
        XCTAssertEqual(string(f, "[texture.isPlaying(), texture.getFrame()].join()"), "false,9",
                       "an int frame; in control already, the play state stays")
        XCTAssertEqual(f.store.animations[texture, Layout.time], 0)

        f.evaluate("texture.join(); texture.setFrame(200)")
        XCTAssertEqual(string(f, "[texture.isPlaying(), texture.getFrame()].join()"), "true,200",
                       "taking control with setFrame plays; not range-checked")
        f.evaluate("texture.join()")
        XCTAssertEqual(string(f, "texture.getFrame()"), "4", "joined: the shared frame again")
    }

    /// The renderer's side of a texture animation for one layer, through the buffer.
    private struct TextureDriver {
        let slot: Int
        let shared: SceneTextureAnimationClock
        var control = SceneTextureAnimationControl()
        var tick: UInt64 = 0

        func publish(_ buffer: SceneScriptSlotBuffer) {
            buffer.write([control.rate, Float(control.frame), control.playing ? 1 : 0,
                          Float(control.overridden ? Flags.overridden : 0), control.time,
                          Float(shared.frame), shared.time, 0], slot: slot, offset: 0)
        }

        mutating func readBack(_ buffer: SceneScriptSlotBuffer) {
            guard buffer.dirty[slot] != 0 else { return }
            buffer.dirty[slot] = 0
            control.rate = buffer[slot, Layout.rate]
            control.frame = Int32(buffer[slot, Layout.frame])
            control.time = buffer[slot, Layout.time]
            control.playing = buffer[slot, Layout.playing] != 0
            control.overridden = Int(buffer[slot, Layout.flags]) & Flags.overridden != 0
        }

        mutating func draw(delta: Float) {
            tick += 1
            shared.advance(tick: tick, delta: delta)
            control.advance(delta: delta, frameTimes: shared.frameTimes)
        }
    }

    /// 2963872291's music icon: `rate = 5` until `getFrame() == 30`, then `rate = 0`; the layer
    /// stops on frame 30 while the texture's shared clock goes on.
    func testTheIconRunsToFrameThirtyAndHolds() throws {
        let f = try fixture()
        f.add("icon", slot: 0, """
            function update(value) {
                let layer = thisLayer.getTextureAnimation();
                if (layer.getFrame() == 30) {
                    layer.rate = 0;
                } else {
                    layer.rate = 5;
                }
                shared.frame = layer.getFrame();
            }
            """)
        f.runtime.load()
        var driver = TextureDriver(slot: try slot(f, "texture"),
                                   shared: SceneTextureAnimationClock(frameTimes: [Float](repeating: 0.03, count: 147)))
        for _ in 0..<120 {
            driver.publish(f.store.animations)
            f.runtime.frame(deltaTime: 1.0 / 60)
            driver.readBack(f.store.animations)
            driver.draw(delta: 1.0 / 60)
        }
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(f.evaluate("shared.frame")?.toInt32(), 30)
        XCTAssertEqual(driver.control.frame, 30)
        XCTAssertTrue(driver.control.overridden)
        XCTAssertNotEqual(driver.shared.frame, 30, "other users of the texture keep the shared clock")
    }

    /// Its other script: `rate = 9; stop()` at init holds frame 0.
    func testRateThenStopAtInitHoldsFrameZero() throws {
        let f = try fixture()
        f.add("init", slot: 0, "function init(value) { thisLayer.getTextureAnimation().rate = 9; thisLayer.getTextureAnimation().stop(); return value; }")
        var driver = TextureDriver(slot: try slot(f, "texture"),
                                   shared: SceneTextureAnimationClock(frameTimes: [Float](repeating: 0.03, count: 147)))
        driver.publish(f.store.animations)
        f.runtime.load()
        driver.readBack(f.store.animations)
        for _ in 0..<30 {
            driver.draw(delta: 1.0 / 60)
            driver.publish(f.store.animations)
            f.runtime.frame(deltaTime: 1.0 / 60)
            driver.readBack(f.store.animations)
        }
        XCTAssertEqual(driver.control, SceneTextureAnimationControl(rate: 9, frame: 0, time: 0, playing: false, overridden: true))
        XCTAssertEqual(string(f, "texture.getFrame() + ',' + texture.isPlaying()"), "0,false")
    }

    // MARK: - animationEvent

    func testAnimationEventsReachTheOwnersScriptsAndApplyTheirReturn() throws {
        let f = try fixture()
        f.add("alpha", slot: 0, binding: .layer(slot: 0, property: "alpha"), initialValue: 1, """
            function animationEvent(event, value) {
                shared.alpha = [event.name, event.frame, value].join();
                return value / 2;
            }
            """)
        f.add("layer", slot: 0, """
            function animationEvent(event, value) { shared.layer = event.name; }
            """)
        f.add("other", slot: 1, "function animationEvent(event) { shared.other = event.name; }")
        f.add("multiply", slot: 0, binding: .material(slot: 0, effect: 0, material: 0, constant: "multiply"),
              initialValue: 1, "function animationEvent(event, value) { shared.material = event.name; }")
        f.runtime.load()
        let bounce = try slot(f, "bounce")
        f.runtime.inbox.post(.animationEvent(animationSlot: bounce, name: "sword", frame: 12))
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(string(f, "shared.alpha"), "sword,12,1")
        XCTAssertEqual(f.evaluate("__rt.valueOf('alpha')")?.toDouble(), 0.5, "the return is applied")
        XCTAssertEqual(string(f, "shared.layer"), "sword", "every script attached to the owner")
        XCTAssertEqual(string(f, "String(shared.other) + ',' + String(shared.material)"), "undefined,undefined",
                       "not another layer's, nor the layer's material's")

        let fade = try slot(f, "sprite.getEffect(0).getMaterial(0).getAnimation('fade')")
        f.runtime.inbox.post(.animationEvent(animationSlot: fade, name: "flash", frame: 3))
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(string(f, "shared.material"), "flash", "a material's animation goes to the material's scripts")
        XCTAssertEqual(string(f, "shared.layer"), "sword")
    }
}

private extension SceneScriptObjectFixture {
    /// The fixture with `compiler`, for callbacks `TestSceneScriptCompiler` doesn't export.
    init(_ host: FakeSceneScriptObjectHost, compiler: SceneScriptModuleCompiling) throws {
        self.host = host
        scriptHost = TestSceneScriptHost()
        model = SceneScriptObjectModel(host: host, capacity: .standard)
        runtime = try SceneScriptRuntime(host: scriptHost, compiler: compiler, extensions: [model])
    }
}
