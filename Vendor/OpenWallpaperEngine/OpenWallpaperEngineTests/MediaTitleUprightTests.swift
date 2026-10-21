import CoreGraphics
import XCTest
@testable import OpenWallpaperEngine

/// `Scenes/media-title`, the shape of 3546971487's media area: a parent whose `scale` is a
/// `startpaused` relative timeline starting upside down (y 1 − 1.5), played by its script's
/// `mediaThumbnailChanged`, holding a song title set by `mediaPropertiesChanged`. WE holds a paused
/// timeline's first key, so the title stays upside down until a thumbnail event plays it.
///
/// The media comes through the real `MacMediaSessionSource` from a player that sends a title and no
/// artwork, as a browser tab on macOS does: the source gives the item the player's icon as its
/// thumbnail, so the timeline plays and the title stands upright.
final class MediaTitleUprightTests: XCTestCase {
    private var storage: URL!

    override func setUpWithError() throws {
        storage = FileManager.default.temporaryDirectory.appending(path: "owe-media-title-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let storage, FileManager.default.fileExists(atPath: storage.path) {
            try FileManager.default.removeItem(at: storage)
        }
    }

    func testASongWithoutArtworkFlipsTheTitleUprightWithThePlayersIcon() throws {
        let scale = try mediaAreaScale(info: Self.song(player: "com.example.player"), icon: Self.icon())
        XCTAssertEqual(scale, 1, accuracy: 1e-4, "the thumbnail event played the timeline to its last key")
    }

    /// Without a player to take an icon from, no thumbnail event comes (WE sends none for an item
    /// without one), and the paused timeline holds its first key, as in WE.
    func testASongWithoutArtworkOrPlayerHoldsTheFirstKey() throws {
        let scale = try mediaAreaScale(info: Self.song(player: nil), icon: Self.icon())
        XCTAssertEqual(scale, 1 - 1.5, accuracy: 1e-4)
    }

    /// An app without an icon gives no thumbnail either.
    func testAPlayerWithoutAnIconGivesNoThumbnail() throws {
        let scale = try mediaAreaScale(info: Self.song(player: "com.example.player"), icon: nil)
        XCTAssertEqual(scale, 1 - 1.5, accuracy: 1e-4)
    }

    // MARK: - Support

    /// The media area's y scale after a second of the song.
    private func mediaAreaScale(info: [String: Any], icon: CGImage?) throws -> Float {
        let framework = PlayingFramework(info: info)
        let asked = Counter()
        let source = MacMediaSessionSource(framework: framework, playerIcon: { _ in
            asked.increment()
            return icon
        })
        let services = SceneScriptServices(prelude: SceneScriptPrelude.load(), storage: SceneScriptStorage(directory: storage),
                                           media: source, spectrum: { .silent })
        let harness = try SceneFrameHarness(directory: Fixtures.url("Scenes/media-title"), size: SIMD2(192, 108),
                                            services: services)
        defer { harness.close() }
        let probe = SceneDrawProbe()
        harness.renderer.drawProbe = probe
        for _ in 0..<60 {
            for _ in 0..<4 { source.flush() }
            harness.draw(frames: 1)
        }
        XCTAssertLessThanOrEqual(asked.value, 1, "the icon is looked up once per player")
        XCTAssertNotNil(probe.layers["2"], "the title draws")
        return try XCTUnwrap(probe.layers["1"], "the media area draws").local.scale.y
    }

    /// A song playing with a title and no artwork, from `player` when given.
    private static func song(player: String?) -> [String: Any] {
        var info: [String: Any] = [MediaRemote.Key.title: "Right Here", MediaRemote.Key.artist: "Someone",
                                   MediaRemote.Key.playbackRate: 1.0]
        if let player { info[MediaRemote.Key.playerBundleIdentifier] = player }
        return info
    }

    /// A 4 × 4 orange square.
    private static func icon() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return try XCTUnwrap(context.makeImage())
    }
}

/// A now-playing service with one playing item.
private final class PlayingFramework: NowPlayingFramework {
    let notificationNames = [Notification.Name("OpenWallpaperEngineTests.mediaTitle.\(UUID().uuidString)")]
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

/// A count bumped from the media source's queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
