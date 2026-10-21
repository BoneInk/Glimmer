import XCTest
@testable import OpenWallpaperEngine

/// `SceneAnimationSet`: which sites a scene's animations land on, parent links, events, script
/// control and rates (docs/timeline-plan.md §2.1, §2.5, §3.1, §3.3), and the instance's texture
/// clocks (§2.7, §3.2). `Tests/Fixtures/Timeline/animation-set-scene.json` holds library shapes:
/// 3187908708's `Title` origin driving its `alpha`, the shared thumbnail `multiply` fade on a
/// material, a looping `alpha` with events, a particle override and a scene setting.
final class SceneAnimationSetTests: XCTestCase {
    private let origin = SceneAnimationSite(owner: .object(7), key: "origin")
    private let titleAlpha = SceneAnimationSite(owner: .object(7), key: "alpha")
    private let thumbnailAlpha = SceneAnimationSite(owner: .object(12), key: "alpha")
    private let multiply = SceneAnimationSite(owner: .material(object: 12, effect: 0, pass: 0), key: "multiply")
    private let sparks = SceneAnimationSite(owner: .particleInstance(2), key: "alpha")
    private let bloom = SceneAnimationSite(owner: .scene, key: "bloomstrength")

    private func fixtureSet() throws -> SceneAnimationSet {
        let document = try JSONDecoder().decode(SceneJSON.self, from: Fixtures.data("Timeline/animation-set-scene.json"))
        return SceneAnimationSet(document: document, wallpaperID: "fixture")
    }

    // MARK: - Construction

    func testEveryAnimatedSiteOfTheSceneIsFound() throws {
        let set = try fixtureSet()
        // `scale` has no fps (logged, left out); `general.properties` is the user-property table.
        XCTAssertEqual(set.sites, [titleAlpha, origin, thumbnailAlpha, multiply, sparks, bloom])
        XCTAssertFalse(set.contains(SceneAnimationSite(owner: .object(7), key: "scale")))
        XCTAssertFalse(set.contains(SceneAnimationSite(owner: .scene, key: "properties")))
    }

    func testValuesAtLoadAreTheTimelinesNotTheStaticValues() throws {
        let set = try fixtureSet()
        // The relative origin is baked on its authored value; its first key is at frame 5.
        let value = try XCTUnwrap(set.value(of: origin))
        XCTAssertEqual(value[0], -137.0976 + 0.0003, accuracy: 1e-3)
        XCTAssertEqual(value[1], 619.67834 + 28.875731, accuracy: 1e-3)
        // A `startpaused` fade holds its first key (1), not its `value` (0).
        XCTAssertEqual(set.value(of: multiply), [1])
        XCTAssertEqual(set.value(of: titleAlpha), [0])
    }

    func testScriptPropertiesMapToSites() {
        let cases: [(String, Int?, Int?, Int?, SceneAnimationSite)] = [
            ("alpha", 7, nil, nil, titleAlpha),
            ("multiply", 12, 0, 0, multiply),
            ("instanceoverride.alpha", 2, nil, nil, sparks),
            ("general.bloomstrength", nil, nil, nil, bloom),
            ("visible", 12, 1, nil, SceneAnimationSite(owner: .effect(object: 12, effect: 1), key: "visible")),
            ("animationlayers.3.blend", 124, nil, nil, SceneAnimationSite(owner: .animationLayer(object: 124, layer: 3), key: "blend")),
        ]
        for (property, object, effect, material, site) in cases {
            XCTAssertEqual(SceneAnimationSite(scriptProperty: property, objectID: object, effect: effect, material: material),
                           site, property)
            XCTAssertEqual(site.scriptProperty, property)
        }
        XCTAssertNil(SceneAnimationSite(scriptProperty: "alpha", objectID: nil, effect: nil, material: nil))
        XCTAssertNil(SceneAnimationSite(scriptProperty: "multiply", objectID: 1, effect: nil, material: 0))
        XCTAssertNil(SceneAnimationSite(scriptProperty: "animationlayers.x.blend", objectID: 1, effect: nil, material: nil))
        XCTAssertNil(SceneAnimationSite(scriptProperty: "animationlayers.2", objectID: 1, effect: nil, material: nil))
    }

    /// 3159348391's moves: a model's animation layer whose `blend` is a named, start-paused,
    /// single timeline (`go`, 0 → 1 → 0 over 15 frames, an event at frame 0) is a site of its own
    /// (`animationlayers[1].blend`), which scripts play and whose event fires as the object's.
    func testAnAnimationLayersBlendTimelineIsASite() throws {
        let keys: [SceneJSON] = [(0, 0), (3, 1), (12, 1), (15, 0)].map {
            .object(["frame": .number($0.0), "value": .number($0.1)])
        }
        let options: SceneJSON = .object([
            "fps": .number(30), "length": .number(15), "mode": .string("single"), "name": .string("go"),
            "startpaused": .bool(true), "events": .array([.object(["frame": .number(0), "name": .string("kick")])]),
        ])
        let model: SceneJSON = .object([
            "id": .number(124), "model": .string("models/dancer.mdl"),
            "animationlayers": .array([
                .object(["animation": .number(119), "blend": .number(1), "rate": .number(4)]),
                .object(["animation": .number(120), "rate": .number(1),
                         "blend": .object(["value": .number(0), "animation": .object(["c0": .array(keys), "options": options])])]),
            ]),
        ])
        let set = SceneAnimationSet(document: .object(["objects": .array([model])]), wallpaperID: "fixture")
        let blend = SceneAnimationSite(owner: .animationLayer(object: 124, layer: 1), key: "blend")
        XCTAssertEqual(set.sites, [blend])
        XCTAssertEqual(set.site(named: "go", owner: .animationLayer(object: 124, layer: 1)), blend)
        XCTAssertEqual(set.value(of: blend), [0])
        for _ in 0..<10 { XCTAssertTrue(set.advance(by: 1 / 30).events.isEmpty, "start-paused") }
        XCTAssertEqual(set.value(of: blend), [0])

        set.perform(.play, on: blend)
        XCTAssertEqual(set.advance(by: 1 / 30).events, [SceneAnimationEvent(site: blend, name: "kick", frame: 0)])
        for _ in 0..<5 { set.advance(by: 1 / 30) }
        XCTAssertEqual(set.value(of: blend)?[0] ?? 0, 1, accuracy: 1e-4, "frame 6: the move is laid over the idle")
        for _ in 0..<12 { set.advance(by: 1 / 30) }
        XCTAssertEqual(set.value(of: blend)?[0] ?? 1, 0, accuracy: 1e-4)
        XCTAssertEqual(set.state(of: blend)?.flags.contains(.finished), true)
    }

    func testNamesAreFoundPerOwnerOrAcrossTheScene() throws {
        let set = try fixtureSet()
        XCTAssertEqual(set.site(named: "Title", owner: .object(7)), origin)
        XCTAssertNil(set.site(named: "Title", owner: .object(12)))
        XCTAssertEqual(set.site(named: "fade"), multiply)
        XCTAssertEqual(set.site(named: "bloom"), bloom)
        XCTAssertNil(set.site(named: "missing"))
    }

    // MARK: - Links

    func testALinkedChildRunsOnItsParentsClock() throws {
        let set = try fixtureSet()
        XCTAssertEqual(set.clockOwner(of: titleAlpha), origin)
        XCTAssertEqual(set.clockOwner(of: origin), origin)
        // `thisObject.getAnimation().play()` on the origin also runs the alpha (single, 60 frames).
        for _ in 0..<20 { set.advance(by: 1 / 60) }
        XCTAssertGreaterThan(set.value(of: titleAlpha)?[0] ?? 0, 0.2)
        // The child's own clock never moves.
        XCTAssertEqual(set.state(of: titleAlpha)?.time, 0)
        for _ in 0..<60 { set.advance(by: 1 / 60) }
        XCTAssertEqual(set.state(of: origin)?.flags.contains(.finished), true)
        XCTAssertEqual(set.value(of: titleAlpha)?[0] ?? 0, 1, accuracy: 1e-6)
    }

    func testCallsOnALinkedChildChangeNothingVisible() throws {
        let set = try fixtureSet()
        XCTAssertTrue(set.perform(.pause, on: titleAlpha))
        XCTAssertTrue(set.perform(.setRate(0), on: titleAlpha))
        XCTAssertTrue(set.perform(.setFrame(40), on: titleAlpha))
        for _ in 0..<20 { set.advance(by: 1 / 60) }
        XCTAssertEqual(set.state(of: origin)?.time ?? 0, 20 / 60, accuracy: 1e-5)
        XCTAssertGreaterThan(set.value(of: titleAlpha)?[0] ?? 0, 0.2)
        XCTAssertLessThan(set.value(of: titleAlpha)?[0] ?? 1, 1)
        // The call did land on the child's own clock, which scripts read back.
        XCTAssertEqual(set.state(of: titleAlpha)?.frame ?? 0, 40, accuracy: 1e-4)
        XCTAssertEqual(set.state(of: titleAlpha)?.isPlaying, false)
    }

    func testTheParentsRateDrivesTheChild() throws {
        let set = try fixtureSet()
        set.perform(.setRate(2), on: origin)
        for _ in 0..<10 { set.advance(by: 1 / 60) }
        XCTAssertEqual(set.state(of: origin)?.frame ?? 0, 20, accuracy: 1e-4)
        XCTAssertEqual(set.state(of: origin)?.rate, 2)
    }

    func testOneLevelOfLinking() throws {
        // c follows b, b follows a: c samples b's clock, which b's own link never advances; c's
        // iteration advances it (WE takes one level, `anim.parent ?? anim`).
        let key: (Int) -> SceneJSON = { frame in
            .object(["frame": .number(Double(frame)), "value": .number(Double(frame))])
        }
        func animation(parent: String?) -> SceneJSON {
            var options: [String: SceneJSON] = ["fps": .number(10), "length": .number(100), "mode": .string("loop")]
            if let parent { options["parent"] = .object(["key": .string(parent)]) }
            return .object(["c0": .array([key(0), key(100)]), "options": .object(options)])
        }
        let layer: SceneJSON = .object(["id": .number(1),
                                        "a": .object(["animation": animation(parent: nil)]),
                                        "b": .object(["animation": animation(parent: "a")]),
                                        "c": .object(["animation": animation(parent: "b")])])
        let set = SceneAnimationSet(document: .object(["objects": .array([layer])]), wallpaperID: "chain")
        let a = SceneAnimationSite(owner: .object(1), key: "a")
        let b = SceneAnimationSite(owner: .object(1), key: "b")
        let c = SceneAnimationSite(owner: .object(1), key: "c")
        XCTAssertEqual(set.clockOwner(of: c), b)
        set.perform(.setRate(3), on: b)
        set.advance(by: 1)
        XCTAssertEqual(set.state(of: a)?.time, 1)
        XCTAssertEqual(set.state(of: b)?.time, 3)
        XCTAssertEqual(set.state(of: c)?.time, 0)
    }

    // MARK: - Script control

    func testPlayOnAStartPausedSingleRunsOnceAndHolds() throws {
        let set = try fixtureSet()
        for _ in 0..<30 { set.advance(by: 1 / 60) }
        XCTAssertEqual(set.value(of: multiply), [1])
        XCTAssertEqual(set.state(of: multiply)?.isPlaying, false)
        set.perform(.play, on: multiply)
        for _ in 0..<120 { set.advance(by: 1 / 60) }
        XCTAssertEqual(set.value(of: multiply)?[0] ?? 1, 0, accuracy: 0.01)
        XCTAssertEqual(set.state(of: multiply)?.flags.contains(.finished), true)
        // Played again, a finished single restarts from 0.
        set.perform(.play, on: multiply)
        set.advance(by: 1 / 60)
        XCTAssertEqual(set.state(of: multiply)?.time ?? 0, 1 / 60, accuracy: 1e-6)
        XCTAssertGreaterThan(set.value(of: multiply)?[0] ?? 0, 0.9)
    }

    func testRestoreTakesTheScriptFramesState() throws {
        let set = try fixtureSet()
        XCTAssertTrue(set.restore(bloom, time: 0.5, flags: [.paused, .reversed], rate: -1))
        let state = try XCTUnwrap(set.state(of: bloom))
        XCTAssertEqual(state.time, 0.5)
        XCTAssertEqual(state.rate, -1)
        // The mode bit stays; the run-time bits are the script's.
        XCTAssertEqual(state.flags, [.mirror, .paused, .reversed])
        XCTAssertFalse(set.restore(SceneAnimationSite(owner: .scene, key: "nothing"), time: 0, flags: [], rate: 1))
    }

    func testANegativeRateRunsALoopBackwards() throws {
        let set = try fixtureSet()
        set.perform(.setRate(-1), on: thumbnailAlpha)
        set.advance(by: 0.25)
        XCTAssertEqual(set.state(of: thumbnailAlpha)?.time ?? 0, 0.75, accuracy: 1e-6)
    }

    // MARK: - Events

    func testEventsFireOncePerCrossingAsTheOwners() throws {
        let set = try fixtureSet()
        var fired: [String: Int] = [:]
        // Two 1 s loops in steps of 1/8 s: events at frames 0, 15 and 29.5 cross once per loop.
        for _ in 0..<16 {
            let frame = set.advance(by: 0.125)
            XCTAssertTrue(frame.events.allSatisfy { $0.site == thumbnailAlpha })
            frame.events.forEach { fired[$0.name, default: 0] += 1 }
        }
        XCTAssertEqual(fired["start"], 2)
        XCTAssertEqual(fired["mid"], 2)
        XCTAssertEqual(fired["late"], 2)
        XCTAssertEqual(set.advance(by: 0.6).events.first, SceneAnimationEvent(site: thumbnailAlpha, name: "start", frame: 0))
    }

    func testEventsFireBackwardsAcrossAWrap() throws {
        let set = try fixtureSet()
        set.perform(.setRate(-1), on: thumbnailAlpha)
        let names = set.advance(by: 0.1).events.map(\.name)
        XCTAssertEqual(names.first, "start")
        XCTAssertTrue(names.contains("late"))
        XCTAssertFalse(names.contains("mid"))
    }

    func testALinkedChildsOwnEventsNeverFire() throws {
        let key: SceneJSON = .object(["frame": .number(0), "value": .number(0)])
        let events: SceneJSON = .array([.object(["name": .string("child"), "frame": .number(1)])])
        let layer: SceneJSON = .object([
            "id": .number(1),
            "origin": .object(["animation": .object(["c0": .array([key]),
                                                     "options": .object(["fps": .number(10), "length": .number(10)])])]),
            "alpha": .object(["animation": .object(["c0": .array([key]),
                                                    "options": .object(["fps": .number(10), "length": .number(10),
                                                                        "events": events,
                                                                        "parent": .object(["key": .string("origin")])])])]),
        ])
        let set = SceneAnimationSet(document: .object(["objects": .array([layer])]), wallpaperID: "child-events")
        var fired: [SceneAnimationEvent] = []
        for _ in 0..<30 { fired += set.advance(by: 0.05).events }
        XCTAssertEqual(fired, [])
    }

    // MARK: - Instances and objects

    func testTwoDisplaysKeepSeparateClocks() throws {
        let first = try fixtureSet()
        let second = try fixtureSet()
        first.perform(.play, on: multiply)
        for _ in 0..<30 { first.advance(by: 1 / 60) }
        second.advance(by: 1 / 60)
        XCTAssertEqual(second.value(of: multiply), [1])
        XCTAssertNotEqual(first.value(of: multiply), [1])
        XCTAssertEqual(second.frameCounter, 1)
    }

    func testObjectsComeAndGo() throws {
        let set = try fixtureSet()
        set.removeObject(7)
        XCTAssertFalse(set.contains(origin))
        XCTAssertFalse(set.contains(titleAlpha))
        XCTAssertEqual(set.sites, [thumbnailAlpha, multiply, sparks, bloom])
        set.advance(by: 1 / 60)

        let document = try JSONDecoder().decode(SceneJSON.self, from: Fixtures.data("Timeline/animation-set-scene.json"))
        let title = try XCTUnwrap(SceneScriptSceneDescriber.objects(of: document).first)
        set.addObject(title, id: 40)
        let created = SceneAnimationSite(owner: .object(40), key: "alpha")
        XCTAssertEqual(set.clockOwner(of: created), SceneAnimationSite(owner: .object(40), key: "origin"))
        XCTAssertEqual(set.value(of: created), [0])
    }

    // MARK: - Textures

    func testLayersOfOneTextureShareItsClock() {
        let set = SceneAnimationSet(wallpaperID: "textures")
        set.textures.register(object: 1, texture: "materials/a.tex", frameTimes: [0.1, 0.1, 0.1])
        set.textures.register(object: 2, texture: "materials/a.tex", frameTimes: [0.1, 0.1, 0.1])
        set.advance(by: 0.1)
        XCTAssertEqual(set.drawnTextureFrame(object: 1, delta: 0.1), 1)
        // The second user in the same engine frame doesn't step the shared clock again.
        XCTAssertEqual(set.drawnTextureFrame(object: 2, delta: 0.1), 1)
        set.advance(by: 0.1)
        XCTAssertEqual(set.drawnTextureFrame(object: 2, delta: 0.1), 2)
        XCTAssertEqual(set.textures.state(object: 1)?.sharedFrame, 2)
    }

    func testAScriptOverrideAndJoin() {
        let set = SceneAnimationSet(wallpaperID: "textures")
        set.textures.register(object: 1, texture: "materials/a.tex", frameTimes: [0.1, 0.1, 0.1, 0.1])
        set.textures.register(object: 2, texture: "materials/a.tex", frameTimes: [0.1, 0.1, 0.1, 0.1])
        set.advance(by: 0.1)
        _ = set.drawnTextureFrame(object: 1, delta: 0.1)
        XCTAssertTrue(set.textures.perform(.pause, object: 2))
        for _ in 0..<2 {
            set.advance(by: 0.1)
            _ = set.drawnTextureFrame(object: 1, delta: 0.1)
            XCTAssertEqual(set.drawnTextureFrame(object: 2, delta: 0.1), 1)
        }
        XCTAssertEqual(set.textures.state(object: 2)?.control.isPlaying, false)
        set.textures.perform(.join, object: 2)
        set.advance(by: 0.1)
        XCTAssertEqual(set.drawnTextureFrame(object: 2, delta: 0.1), 0)
        XCTAssertEqual(set.textures.state(object: 2)?.frameCount, 4)

        set.removeObject(1)
        XCTAssertNotNil(set.textures.clock(texture: "materials/a.tex"))
        set.removeObject(2)
        XCTAssertNil(set.textures.clock(texture: "materials/a.tex"))
        XCTAssertFalse(set.textures.perform(.play, object: 2))
    }
}
