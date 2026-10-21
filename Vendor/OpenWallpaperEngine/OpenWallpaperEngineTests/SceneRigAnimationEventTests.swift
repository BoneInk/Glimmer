import JavaScriptCore
import XCTest
import simd
@testable import OpenWallpaperEngine

/// Puppet and model clip events reach scripts as WE sends them (docs/models-plan.md §5.26): the
/// object update (0x1401fdf90 for images, 0x14021c480 for models) passes each crossed event's
/// name to the object's scripts as callback 6, `animationEvent` (0x14020022e, 0x14021cdbf), and
/// scenescript64.dll hands the script `JSON.parse(name)` (0x18164eac2), then the layers' ended
/// callbacks run (0x140200290…0x1402002f1), all before the scripts' `update`.
final class SceneRigAnimationEventTests: XCTestCase {
    /// WE's editor stores a clip event's name as the event's JSON (2321732083's `.mdl`).
    private static let sword = #"{"$$hashKey":"object:752","frame":0,"name":"sword"}"#

    private func fixture() throws -> SceneScriptObjectFixture {
        var image = SceneScriptObjectDescription.make(.image, id: 5, name: "puppet")
        image.rig = SceneScriptRigTests.rig
        let plain = SceneScriptObjectDescription.make(.image, id: 6, name: "plain")
        return try SceneScriptObjectFixture(FakeSceneScriptObjectHost(scene: SceneScriptSceneDescription(objects: [image, plain])),
                                            allCallbacks: true)
    }

    private func string(_ f: SceneScriptObjectFixture, _ script: String) -> String? { f.evaluate(script)?.toString() }

    /// The object's scripts get each event, parsed, with their value, then the ended callbacks,
    /// then `update`; another object's scripts get none. A name that isn't JSON is `undefined`.
    func testClipEventsReachTheObjectsScriptsBeforeTheirUpdate() throws {
        let f = try fixture()
        let puppet = try XCTUnwrap(f.model.slot(forObjectID: 5)), plain = try XCTUnwrap(f.model.slot(forObjectID: 6))
        f.add("puppet", slot: puppet, initialValue: 3, """
            function log(entry) { shared.log = (shared.log || []).concat([entry]); }
            function animationEvent(event, value) { log(JSON.stringify(event) + '|' + value); }
            function update(value) { log('update'); return value; }
            """)
        f.add("plain", slot: plain, "function animationEvent(event) { shared.plain = true; }")
        f.runtime.load()
        f.evaluate("""
            thisScene.getLayer('puppet').getAnimationLayer(0).addEndedCallback(function () {
                shared.log = (shared.log || []).concat(['ended']);
            });
            """)
        let rigSlot = try XCTUnwrap(f.store.rigSlot(of: puppet))
        let feedback = SceneScriptRigFeedback(
            layers: [.init(key: 47, name: "idle", clip: 0, time: 0.5, frame: 15, flags: [], rate: 1, blend: 1, visible: true,
                           additive: false)],
            locals: (0..<3).map { _ in matrix_identity_float4x4 }, worlds: (0..<3).map { _ in matrix_identity_float4x4 },
            ended: [47], events: [.init(layer: 47, name: Self.sword, frame: 0), .init(layer: 47, name: "plain name", frame: 4)])
        SceneScriptRigMirror().publish([5: feedback], into: f.store.rigs) { $0 == 5 ? rigSlot : nil }
        f.runtime.inbox.post(.rigAnimation(objectSlot: puppet, events: feedback.events.map(\.name)))
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertTrue(f.scriptHost.errors.isEmpty, "\(f.scriptHost.errors)")
        XCTAssertEqual(string(f, "shared.log.join('\\n')"),
                       [Self.sword + "|3", "undefined|3", "ended", "update"].joined(separator: "\n"))
        XCTAssertEqual(string(f, "String(shared.plain)"), "undefined", "only the object's own scripts")

        // Once per end: the next frame calls nothing but `update`.
        f.evaluate("shared.log = [];")
        var quiet = feedback
        quiet.ended = []
        quiet.events = []
        SceneScriptRigMirror().publish([5: quiet], into: f.store.rigs) { $0 == 5 ? rigSlot : nil }
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(string(f, "shared.log.join()"), "update")
    }

    /// Rig events come before the frame's cursor, media and timeline events (WE's object loop,
    /// 0x14017fd26, runs before the cursor pass, 0x1401802d5, and the scene update, 0x1401802e5).
    func testRigEventsComeFirstInTheFrame() throws {
        let f = try fixture()
        let puppet = try XCTUnwrap(f.model.slot(forObjectID: 5))
        f.add("puppet", slot: puppet, """
            function animationEvent(event) { shared.log = (shared.log || []).concat([event === undefined ? 'rig' : 'x']); }
            function applyUserProperties() { shared.log = (shared.log || []).concat(['properties']); }
            """)
        f.runtime.load()
        f.evaluate("shared.log = [];")
        f.runtime.inbox.post(SceneScriptEvent(kind: .userProperties, payload: ["a": 1]))
        f.runtime.inbox.post(.rigAnimation(objectSlot: puppet, events: ["not json"]))
        f.runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(string(f, "shared.log.join()"), "rig,properties")
    }

    /// The animator keeps the events its layers crossed until scripts take them.
    func testTheAnimatorCollectsItsClipEvents() throws {
        let clip = SceneAnimationLayersTests.clip(id: 1, fps: 10, frames: 20, bones: 1,
                                                  events: [.init(frame: 0, name: "start"), .init(frame: 5, name: "half")],
                                                  pose: SceneAnimationLayersTests.still())
        let skeleton = MDLSkeleton(version: 1, bones: [MDLBone(name: "b0", flags: 1, parent: 0xFFFF_FFFF,
                                                               matrix: matrix_identity_float4x4, properties: "")])
        let layers = try JSONDecoder().decode([WEAnimationLayer].self, from: Data(#"[{"animation": 1, "id": 3}]"#.utf8))
        let animator = ScenePuppetAnimator(skeleton: skeleton, clips: [clip], layers: layers)
        animator.advance(delta: 0.1, values: EmptySceneValues())
        animator.advance(delta: 0.45, values: EmptySceneValues())
        XCTAssertEqual(animator.takeEvents().map(\.name), ["start", "half"])
        XCTAssertEqual(animator.takeEvents().map(\.name), [], "taken once")
        animator.advance(delta: 0.1, values: EmptySceneValues())
        XCTAssertEqual(animator.takeEvents().map(\.name), [])
    }
}

extension SceneRigAnimationEventTests {
    /// Through the script thread's frame (`SceneScriptWallpaper`, the mirror): the renderer's rig
    /// feedback with events reaches the object's own `animationEvent`, parsed, before `update`,
    /// and ahead of the frame's timeline events.
    func testTheWallpapersFrameSendsRigEvents() throws {
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-rig-events-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) } // Optional: the folder may not exist.
        let script = """
            export function animationEvent(event, value) {
                shared.log = (shared.log || []).concat([(event === undefined ? 'undefined' : event.name) + ':' + (shared.updates || 0)]);
            }
            export function update(value) { shared.updates = (shared.updates || 0) + 1; return value; }
            """
        let objects = [#"{"id": 1, "name": "Puppet", "image": "models/a.json", "alpha": {"script": \#(Self.quoted(script)), "value": 1}}"#,
                       #"{"id": 2, "name": "Other", "image": "models/b.json", "alpha": {"script": "export function animationEvent() { shared.other = 1; }", "value": 1}}"#]
        let text = #"{"general": {"orthogonalprojection": {"width": 200, "height": 100}}, "objects": [\#(objects.joined(separator: ", "))]}"#
        let document = try SceneScriptSiteBuilder.document(from: Data(text.utf8))
        let content = SceneScriptSceneContent(wallpaperID: "rig-\(UUID().uuidString.prefix(8))", document: document,
                                              documentSignature: "1", project: nil, userValues: { [:] },
                                              file: { _ in nil }, makeLayer: { _ in nil })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let wallpaper = try XCTUnwrap(try SceneScriptWallpaper(content: content, services: services, screenID: "test"))
        addTeardownBlock { wallpaper.tearDown(); wallpaper.waitUntilIdle() }
        var input = SceneScriptFrameInput()
        input.deltaTime = 1.0 / 60
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        _ = wallpaper.take()
        input.rigs[1] = SceneScriptRigFeedback(events: [.init(layer: 3, name: Self.sword, frame: 0), .init(layer: 3, name: "x", frame: 2)])
        wallpaper.submit(input)
        wallpaper.waitUntilIdle()
        _ = wallpaper.take()
        let log = wallpaper.thread.sync { wallpaper.scriptRuntime?.context.evaluateScript("shared.log.join() + '/' + shared.other")?.toString() }
        XCTAssertEqual(log, "sword:1,undefined:1/undefined", "before the frame's update, to the object's own scripts only")
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8) // Optional: a string always encodes.
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

extension SceneRigAnimationEventTests {
    /// End to end on the Samurai (2321732083, the library's one clip event: its `sword` clip's,
    /// at frame 0): a script on the puppet reads, in its `update`, the `sword` layer's frame as
    /// this frame's evaluation left it (the object loop ran first), and gets the event, parsed,
    /// before the `update` of the frame that crossed it. Skipped without the library.
    func testTheSamuraisScriptSeesThisFramesPoseAndItsSwordEvent() throws {
        let source = LibrarySweepTests.libraryRoot.appending(path: "2321732083")
        let sceneURL = source.appending(path: "scene.json")
        guard FileManager.default.fileExists(atPath: sceneURL.path) else { throw XCTSkip("2321732083 isn't in the library") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "owe-samurai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) } // Optional: cleanup only.
        // Copies, not links: the loader refuses an asset whose links resolve outside the wallpaper's
        // folder (`AssetPathResolver`), so linked folders would leave the puppet without its rig.
        for name in try FileManager.default.contentsOfDirectory(atPath: source.path) where name != "scene.json" {
            try FileManager.default.copyItem(at: source.appending(path: name), to: directory.appending(path: name))
        }
        let script = """
            export function update(value) {
                shared.frames = (shared.frames || []).concat([thisLayer.getAnimationLayer('sword').getFrame()]);
                return value;
            }
            export function animationEvent(event, value) {
                shared.events = (shared.events || []).concat([event.name + '@' + (shared.frames || []).length]);
            }
            """
        var document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: sceneURL)) as? [String: Any])
        var objects = try XCTUnwrap(document["objects"] as? [[String: Any]])
        let index = try XCTUnwrap(objects.firstIndex { ($0["id"] as? Int) == 29 })
        objects[index]["alpha"] = ["script": script, "value": 1.0]
        document["objects"] = objects
        try JSONSerialization.data(withJSONObject: document).write(to: directory.appending(path: "scene.json"))

        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-samurai-storage-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) } // Optional: cleanup only.
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: SceneScriptReplayMediaSource(), spectrum: { .silent })
        let scene = try SceneFrameHarness(directory: directory, services: services)
        defer { scene.close() }
        let draws = 40
        scene.draw(frames: draws)
        XCTAssertEqual(try scene.evaluate("shared.events.join()"), "sword@1",
                       "crossed by the first step (the first draw only anchors the clock), before that frame's update")

        // The frames the script read against the clip's clock stepped as the renderer steps it.
        let model = try MDLReader.read(Data(contentsOf: source.appending(path: "models/samurai_puppet.mdl")))
        let clip = try XCTUnwrap(model.animations?.first { $0.id == 105 })
        var clock = SceneAnimationLayer.clock(for: clip)
        var expected: [Float] = [clock.frame]
        for _ in 1..<draws {
            _ = clock.advance(by: Float(1.0 / 60) * Float(0.25999999))
            expected.append(clock.frame)
        }
        let read = try XCTUnwrap(try scene.evaluate("shared.frames.join()")).split(separator: ",").compactMap { Float($0) }
        XCTAssertEqual(read.count, draws)
        for (index, frame) in read.enumerated() {
            XCTAssertEqual(frame, expected[index], accuracy: 1e-3, "update \(index): this frame's evaluation, not the last one's")
        }
        XCTAssertGreaterThan(read.last ?? 0, 0)
    }
}

private extension SceneScriptObjectFixture {
    /// The fixture with every callback WE calls exported (`AllCallbacksTestSceneScriptCompiler`).
    init(_ host: FakeSceneScriptObjectHost, allCallbacks: Bool) throws {
        self.host = host
        scriptHost = TestSceneScriptHost()
        model = SceneScriptObjectModel(host: host, capacity: .standard)
        runtime = try SceneScriptRuntime(host: scriptHost, compiler: AllCallbacksTestSceneScriptCompiler(), extensions: [model])
    }
}
