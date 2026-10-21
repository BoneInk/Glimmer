import JavaScriptCore
import XCTest
@testable import OpenWallpaperEngine

/// A media source the test drives.
private final class FakeMediaSessionSource: MediaSessionSource {
    private var subscribers: [Int: (MediaSessionState) -> Void] = [:]
    private var nextID = 0

    var subscriberCount: Int { subscribers.count }

    func subscribe(_ update: @escaping (MediaSessionState) -> Void) -> Int {
        nextID += 1
        subscribers[nextID] = update
        return nextID
    }

    func unsubscribe(_ id: Int) { subscribers[id] = nil }
    func send(_ state: MediaSessionState) { for update in subscribers.values { update(state) } }
}

/// MediaRemote as the test drives it. `lock` owns every var.
private final class FakeNowPlayingFramework: NowPlayingFramework {
    let notificationNames = [Notification.Name("OpenWallpaperEngineTests.nowPlaying.\(UUID().uuidString)")]
    private let lock = NSLock()
    private var _info: [String: Any] = [:]
    private var _registrations = 0
    private var _unregistrations = 0
    private var _delay: TimeInterval = 0

    var info: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return _info }
        set { lock.lock(); _info = newValue; lock.unlock() }
    }
    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }
    var registrations: Int { lock.lock(); defer { lock.unlock() }; return _registrations }
    var unregistrations: Int { lock.lock(); defer { lock.unlock() }; return _unregistrations }

    func register(on queue: DispatchQueue) { lock.lock(); _registrations += 1; lock.unlock() }
    func unregister() { lock.lock(); _unregistrations += 1; lock.unlock() }

    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void) {
        let delay = self.delay, info = self.info
        queue.async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            handler(info)
        }
    }

    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void) {
        queue.async { handler(false) }
    }

    func postChange() {
        NotificationCenter.default.post(name: notificationNames[0], object: nil)
    }
}

/// `TestSceneScriptCompiler` with every callback WE calls exported.
private struct MediaTestCompiler: SceneScriptModuleCompiling {
    private static let exportNames = ["init", "update", "destroy", "mediaStatusChanged", "mediaPlaybackChanged",
                                      "mediaPropertiesChanged", "mediaThumbnailChanged", "mediaTimelineChanged"]

    func compile(_ source: String) throws -> SceneScriptCompiledModule {
        let getters = Self.exportNames
            .map { "get \($0)() { return typeof \($0) === 'undefined' ? undefined : \($0); }" }
            .joined(separator: ", ")
        let header = "(function (__rt, __scope) { 'use strict'; var thisLayer = __scope.thisLayer, thisObject = __scope.thisObject; "
        return SceneScriptCompiledModule(factorySource: header + source + "\nreturn { \(getters) }; })")
    }
}

/// The five media callbacks (docs/scenescript-plan.md WP6): WE's event objects, WE's order, the
/// current state right after `init`, and no event twice.
final class SceneScriptMediaTests: XCTestCase {
    /// Logs every media callback into `shared.log[<name>]`.
    private static func loggingScript(_ name: String) -> String {
        """
        shared.log = shared.log || {};
        shared.log['\(name)'] = [];
        function log(entry) { shared.log['\(name)'].push(entry); }
        function init(value) { log('init'); return value; }
        function mediaStatusChanged(event) { log('status ' + event.enabled); }
        function mediaPlaybackChanged(event) { log('playback ' + event.state); }
        function mediaPropertiesChanged(event) {
            log('properties ' + [event.title, event.artist, event.subTitle, event.albumTitle, event.albumArtist,
                                 event.genres, event.contentType].join('|'));
        }
        function mediaThumbnailChanged(event) {
            log('thumbnail ' + event.hasThumbnail + ' ' + (event.primaryColor instanceof Vec3) + ' ' +
                [event.primaryColor, event.secondaryColor, event.tertiaryColor, event.textColor,
                 event.highContrastColor].map(function (c) { return c.toString(); }).join(','));
        }
        function mediaTimelineChanged(event) { log('timeline ' + event.position + '/' + event.duration); }
        """
    }

    private let source = FakeMediaSessionSource()

    private func makeRuntime() throws -> SceneScriptRuntime {
        try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: MediaTestCompiler(),
                               extensions: [SceneScriptMediaExtension(source: source)])
    }

    private func log(_ name: String, in runtime: SceneScriptRuntime) -> [String] {
        runtime.context.evaluateScript("shared.log['\(name)']")?.toArray() as? [String] ?? []
    }

    private var playing: MediaSessionState {
        var state = MediaSessionState()
        state.enabled = true
        state.playback = .playing
        state.properties = .init(title: "Song", artist: "Artist", albumTitle: "Album", genres: "Pop,Rock",
                                 contentType: "audio")
        state.thumbnail = .init(artwork: 1, colors: ArtworkPalette.Colors(
            primary: SIMD3(1, 0, 0), secondary: SIMD3(0, 0, 1), tertiary: SIMD3(0, 1, 0),
            text: SIMD3(0, 1, 0), highContrast: .zero))
        state.timeline = .init(position: 10, duration: 200)
        return state
    }

    func testANewScriptGetsTheCurrentStateRightAfterInitAndNothingTwice() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        source.send(playing)
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        let expected = [
            "init", "status true", "playback 1", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ]
        XCTAssertEqual(log("a", in: runtime), expected)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log("a", in: runtime), expected, "the queued events of the same state are not repeated")
    }

    func testChangesArriveAsEventsInWEOrder() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        XCTAssertEqual(log("a", in: runtime), ["init"], "an empty, disabled state sends nothing at init")

        source.send(playing)
        XCTAssertEqual(log("a", in: runtime), ["init"], "events wait for the next frame")
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(Array(log("a", in: runtime).dropFirst()), [
            "status true", "playback 1", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ])

        var paused = playing
        paused.playback = .paused
        source.send(paused)
        var next = paused
        next.timeline.position = 11
        source.send(next)
        source.send(next)
        var noArtwork = next
        noArtwork.thumbnail = .init()
        source.send(noArtwork)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(Array(log("a", in: runtime).dropFirst(6)), [
            "playback 2", "thumbnail false true 0 0 0,0 0 0,0 0 0,0 0 0,0 0 0", "timeline 11/200",
        ], "the newest change of each kind, in WE's callback order")
    }

    func testAPausedWallpaperKeepsTheNewestChangeOfEachKind() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        var state = playing
        source.send(state)
        state.properties.title = "Next"
        source.send(state)
        for second in 0..<1100 {
            state.timeline.position = Double(second)
            source.send(state)
        }
        runtime.frame(deltaTime: 1.0 / 60)
        let entries = log("a", in: runtime)
        XCTAssertEqual(entries.filter { $0.hasPrefix("properties") }, ["properties Next|Artist||Album||Pop,Rock|audio"])
        XCTAssertEqual(entries.filter { $0.hasPrefix("timeline") }, ["timeline 1099/200"])
    }

    func testAScriptAddedLaterStartsFromTheCurrentState() throws {
        _ = try Fixtures.assets()
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        source.send(playing)
        var paused = playing
        paused.playback = .paused
        source.send(paused)
        runtime.add(SceneScriptInstance(id: "b", source: Self.loggingScript("b")))
        runtime.load()
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log("b", in: runtime), [
            "init", "status true", "playback 2", "properties Song|Artist||Album||Pop,Rock|audio",
            "thumbnail true true 1 0 0,0 0 1,0 1 0,0 1 0,0 0 0", "timeline 10/200",
        ])
        XCTAssertEqual(log("a", in: runtime).filter { $0.hasPrefix("playback") }, ["playback 2"],
                       "both changes came before one frame: the newest")
    }

    func testAThrowingMediaCallbackIsDisabledAlone() throws {
        let runtime = try makeRuntime()
        runtime.add(SceneScriptInstance(id: "a", source: """
            shared.calls = [];
            function mediaPlaybackChanged(event) { shared.calls.push('playback'); throw new Error('boom'); }
            function mediaTimelineChanged(event) { shared.calls.push('timeline'); }
            """))
        runtime.load()
        source.send(playing)
        runtime.frame(deltaTime: 1.0 / 60)
        var later = playing
        later.playback = .paused
        later.timeline.position = 12
        source.send(later)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(runtime.context.evaluateScript("shared.calls.join(',')")?.toString(), "playback,timeline,timeline")
    }

    func testTheSubscriptionEndsWithTheRuntime() throws {
        var runtime: SceneScriptRuntime? = try makeRuntime()
        XCTAssertEqual(source.subscriberCount, 1)
        runtime?.tearDown()
        runtime = nil
        XCTAssertEqual(source.subscriberCount, 0)
    }

    // MARK: - One MediaRemote source for every runtime

    private func waitForSource(_ source: MacMediaSessionSource) {
        // A fetch hops through the queue a few times (info, playing, publish).
        for _ in 0..<4 { source.flush() }
    }

    func testOneRuntimeLeavingDoesNotSilenceTheOther() throws {
        let framework = FakeNowPlayingFramework()
        let shared = MacMediaSessionSource(framework: framework)
        func runtime(_ name: String) throws -> SceneScriptRuntime {
            let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(screenID: name), compiler: MediaTestCompiler(),
                                                 extensions: [SceneScriptMediaExtension(source: shared)])
            runtime.add(SceneScriptInstance(id: name, source: Self.loggingScript(name)))
            runtime.load()
            return runtime
        }
        var first: SceneScriptRuntime? = try runtime("first")
        let second = try runtime("second")
        waitForSource(shared)
        XCTAssertEqual(framework.registrations, 1, "MediaRemote registration is process-wide: once")

        first?.tearDown()
        first = nil
        waitForSource(shared)
        XCTAssertEqual(framework.unregistrations, 0, "another runtime still listens")

        framework.info = [MediaRemote.Key.title: "Next", MediaRemote.Key.artist: "Artist"]
        framework.postChange()
        waitForSource(shared)
        second.frame(deltaTime: 1.0 / 60)
        XCTAssertTrue(log("second", in: second).contains("properties Next|Artist|||||"))
        XCTAssertTrue(log("second", in: second).contains("status true"))

        second.tearDown()
        _ = second
    }

    func testTheLastSubscriberUnregistersWithoutWaitingForAFetch() {
        let framework = FakeNowPlayingFramework()
        let shared = MacMediaSessionSource(framework: framework)
        let id = shared.subscribe { _ in }
        waitForSource(shared)
        framework.delay = 0.5
        framework.postChange()
        Thread.sleep(forTimeInterval: 0.05) // the slow fetch is now running on the source's queue
        let started = Date()
        shared.unsubscribe(id)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "unsubscribe never waits for fetching or decoding")
        waitForSource(shared)
        XCTAssertEqual(framework.unregistrations, 1)
        XCTAssertEqual(framework.registrations, 1)
    }

    func testWithoutMediaRemoteTheStatusStaysDisabled() throws {
        let unavailable = MacMediaSessionSource(framework: nil)
        let runtime = try SceneScriptRuntime(host: TestSceneScriptHost(), compiler: MediaTestCompiler(),
                                             extensions: [SceneScriptMediaExtension(source: unavailable)])
        runtime.add(SceneScriptInstance(id: "a", source: Self.loggingScript("a")))
        runtime.load()
        waitForSource(unavailable)
        runtime.frame(deltaTime: 1.0 / 60)
        XCTAssertEqual(log("a", in: runtime), ["init"], "a disabled, empty state sends nothing")
    }
}
