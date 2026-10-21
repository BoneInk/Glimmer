import XCTest
@testable import OpenWallpaperEngine

/// WE's media blocklist (`mediablocklist`, `settings_media_blocklist_*`): a blocked app's session
/// reaches no wallpaper, which sees nothing playing; the blocklist dialog still names the app.
final class MediaBlocklistTests: XCTestCase {
    private let music: [String: Any] = [
        MediaRemote.Key.title: "Song",
        MediaRemote.Key.artist: "Artist",
        MediaRemote.Key.duration: NSNumber(value: 200),
        MediaRemote.Key.elapsedTime: NSNumber(value: 10),
        MediaRemote.Key.playbackRate: NSNumber(value: 1),
        MediaRemote.Key.sessionBundleIdentifier: "com.example.player",
    ]

    private func latestState(of source: MacMediaSessionSource, _ states: StateBox) -> MediaSessionState? {
        // Subscribing or a change queues a fetch, which queues reading the state, which publishes.
        for _ in 0..<4 { source.flush() }
        return states.last
    }

    func testABlockedAppsSessionLooksLikeNothingPlaying() throws {
        let source = MacMediaSessionSource(framework: SessionFramework(info: music), playerIcon: { _ in nil })
        let states = StateBox()
        let id = source.subscribe { states.append($0) }
        defer { source.unsubscribe(id) }

        let playing = try XCTUnwrap(latestState(of: source, states))
        XCTAssertEqual(playing.properties.title, "Song")
        XCTAssertEqual(playing.playback, .playing)
        XCTAssertEqual(source.currentSessionPlayer, "com.example.player")

        source.setBlocklist(["com.example.player"])
        let blocked = try XCTUnwrap(latestState(of: source, states))
        var nothing = MediaSessionState()
        nothing.enabled = true
        XCTAssertEqual(blocked, nothing, "media integration stays on; only the session is hidden")
        XCTAssertEqual(source.currentSessionPlayer, "com.example.player", "the dialog still names the app to unblock")

        source.setBlocklist([])
        XCTAssertEqual(try XCTUnwrap(latestState(of: source, states)).properties.title, "Song")
    }

    func testOtherAppsAreNotAffected() throws {
        let source = MacMediaSessionSource(framework: SessionFramework(info: music), playerIcon: { _ in nil })
        source.setBlocklist(["com.example.other"])
        let states = StateBox()
        let id = source.subscribe { states.append($0) }
        defer { source.unsubscribe(id) }
        XCTAssertEqual(try XCTUnwrap(latestState(of: source, states)).properties.title, "Song")
    }

    func testTheSessionsAppComesFromEitherKey() {
        XCTAssertEqual(MacMediaSessionSource.sessionPlayer(of: [MediaRemote.Key.sessionBundleIdentifier: "a"]), "a")
        XCTAssertEqual(MacMediaSessionSource.sessionPlayer(of: [MediaRemote.Key.playerBundleIdentifier: "b"]), "b")
        XCTAssertNil(MacMediaSessionSource.sessionPlayer(of: [MediaRemote.Key.sessionBundleIdentifier: ""]))
        XCTAssertNil(MacMediaSessionSource.sessionPlayer(of: [:]))
    }

    func testTheBlocklistIsStoredAndEmptyByDefault() throws {
        XCTAssertEqual(GlobalSettings().mediaBlocklist, [])
        var settings = GlobalSettings()
        settings.mediaBlocklist = ["com.spotify.client"]
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.mediaBlocklist, ["com.spotify.client"])
    }
}

private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [MediaSessionState] = []
    var last: MediaSessionState? { lock.withLock { states.last } }
    func append(_ state: MediaSessionState) { lock.withLock { states.append(state) } }
}

private final class SessionFramework: NowPlayingFramework {
    let notificationNames = [Notification.Name("OpenWallpaperEngineTests.mediaBlocklist.\(UUID().uuidString)")]
    private let info: [String: Any]

    init(info: [String: Any]) { self.info = info }

    func register(on queue: DispatchQueue) {}
    func unregister() {}
    func nowPlayingInfo(on queue: DispatchQueue, _ handler: @escaping ([String: Any]) -> Void) {
        let info = self.info
        queue.async { handler(info) }
    }
    func isPlaying(on queue: DispatchQueue, _ handler: @escaping (Bool) -> Void) {
        queue.async { handler(true) }
    }
}
