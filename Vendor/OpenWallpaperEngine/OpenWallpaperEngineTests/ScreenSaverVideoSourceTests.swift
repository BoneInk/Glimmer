import AVFoundation
import AppKit
import CoreVideo
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Video wallpapers in the screen saver, drawn live by the app: eligibility, the track info that
/// sizes and paces a ring, the placement drawing, and the frames a player of its own or the
/// desktop's player publish (`ScreenSaverLiveVideo`).
@MainActor
final class ScreenSaverVideoSourceTests: XCTestCase {
    private typealias Plugin = ScreenSaverPlugin
    private typealias Video = ScreenSaverLiveVideo
    private var root: URL!

    private final class SilentNotifier: ScreenSaverFrameNotifier, @unchecked Sendable {
        func post(_ name: String, state: UInt64) {}
    }

    /// The desktop's player, as `VideoWallpaperViewModel` lends it.
    private final class DesktopPlayer: ScreenSaverVideoSharing {
        let sharedPlayer: AVPlayer
        private(set) var holds: [Bool] = []
        init(_ player: AVPlayer) { sharedPlayer = player }
        func holdForScreenSaver(_ hold: Bool) {
            holds.append(hold)
            if hold { sharedPlayer.play() }
        }
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ScreenSaverVideoSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func wallpaper(file: String, type: String = "video") -> WEWallpaper {
        WEWallpaper(using: WEProject(file: file, preview: "p.jpg", title: "t", type: type), where: root)
    }

    private func publisher(ring: SIMD2<Int>) throws -> ScreenSaverFramePublisher {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let publisher = ScreenSaverFramePublisher(manifestURL: nil, notifier: SilentNotifier(), device: device)
        try publisher.publish(sizes: [ring], displays: [.init(display: nil, ring: 0)], frameRate: 30)
        return publisher
    }

    /// Runs the main run loop until `publisher` drew `count` frames into ring 0, or 10 s passed.
    private func waitForFrames(_ publisher: ScreenSaverFramePublisher, count: Int) -> Int {
        var drawn = 0
        let deadline = Date().addingTimeInterval(10)
        while drawn < count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            drawn += publisher.takeCounts()[0]?.drawn ?? 0
        }
        return drawn
    }

    /// The red, green and blue of the newest frame's pixel at (`x`, `y`) from the top-left.
    private func pixel(_ publisher: ScreenSaverFramePublisher, x: Int, y: Int) throws -> SIMD3<Int> {
        let image = try XCTUnwrap(publisher.newestImage(ring: 0))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return SIMD3(Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    // MARK: - Eligibility

    func testEligibilityPerContainer() {
        for file in ["video.mp4", "video.MOV", "video.m4v"] {
            XCTAssertTrue(ScreenSaverVideoSource.isEligible(wallpaper(file: file)), file)
            XCTAssertEqual(Plugin.liveKind(of: wallpaper(file: file), chromiumInstalled: false), .video, "drawn live without Chromium")
        }
        for file in ["video.mkv", "https://example.com/video.mp4"] {
            XCTAssertFalse(Plugin.isEligible(wallpaper(file: file)), file)
        }
        // WebM is drawn as a page through Chromium.
        XCTAssertTrue(Plugin.isEligible(wallpaper(file: "video.webm")))
        XCTAssertFalse(ScreenSaverVideoSource.isEligible(wallpaper(file: "video.webm")))
        XCTAssertNotEqual(Plugin.liveKind(of: wallpaper(file: "video.webm"), chromiumInstalled: true), .video)
        XCTAssertTrue(Plugin.isEligible(wallpaper(file: "index.html", type: "web")))
        XCTAssertTrue(Plugin.isEligible(wallpaper(file: "scene.json", type: "scene")))
    }

    func testVideosAreAvailableAtOnce() {
        let video = wallpaper(file: "video.mp4")
        XCTAssertEqual(Plugin.status(for: video, enabled: true, chromiumInstalled: false), .available)
        XCTAssertNil(Plugin.status(for: video, enabled: false, chromiumInstalled: true))
        XCTAssertEqual(Plugin.status(for: wallpaper(file: "video.mkv"), enabled: true, chromiumInstalled: true), .notEligible)
    }

    // MARK: - Track info

    func testTheTrackInfoIsReadOnceAndKept() async throws {
        let clip = try VideoClipFixture.make(frames: 24, fps: 24, in: root)
        XCTAssertNil(ScreenSaverVideoSource.cachedInfo(of: clip), "not read yet")
        let loaded = await ScreenSaverVideoSource.loadInfo(of: clip)
        let info = try XCTUnwrap(loaded)
        XCTAssertEqual(info.size, SIMD2(64, 64))
        XCTAssertEqual(info.frameRate, 24, accuracy: 0.5)
        XCTAssertEqual(ScreenSaverVideoSource.cachedInfo(of: clip), info)
        let missing = await ScreenSaverVideoSource.loadInfo(of: root.appending(path: "missing.mp4"))
        XCTAssertNil(missing)
    }

    // MARK: - Sizing, pacing and placement

    func testTheRingIsNeverLargerThanThePlacedVideo() {
        let uhd = SIMD2(3840, 2160), hd = SIMD2(1920, 1080), fiveK = SIMD2(5120, 2880)
        XCTAssertEqual(Video.ringPixels(loop: fiveK, video: hd, placement: .fill), hd, "a 1080p video on a 5K display: a 1080p ring")
        XCTAssertEqual(Video.ringPixels(loop: hd, video: uhd, placement: .fill), hd, "a 4K video on a 1080p display: the display's")
        XCTAssertEqual(Video.ringPixels(loop: fiveK, video: nil, placement: .fill), fiveK, "unknown yet: the display's")
        XCTAssertEqual(Video.ringPixels(loop: SIMD2(2560, 1600), video: hd, placement: .fit), SIMD2(1920, 1200),
                       "fitted: the bars come with it, the display's shape kept")
        XCTAssertEqual(Video.ringPixels(loop: SIMD2(2560, 1600), video: hd, placement: .fill), SIMD2(1728, 1080))
    }

    func testTheLinkTicksAtTheVideosOwnRate() {
        XCTAssertEqual(Video.frameRate(videoRate: 24, refresh: 60, limit: 60), 30, "every frame of 24 fps shows on a 60 Hz display")
        XCTAssertEqual(Video.frameRate(videoRate: 29.97, refresh: 60, limit: 60), 30)
        XCTAssertEqual(Video.frameRate(videoRate: 30, refresh: 60, limit: 60), 30)
        XCTAssertEqual(Video.frameRate(videoRate: 25, refresh: 60, limit: 60), 30)
        XCTAssertEqual(Video.frameRate(videoRate: 24, refresh: 120, limit: 120), 24)
        XCTAssertEqual(Video.frameRate(videoRate: 60, refresh: 165, limit: 55), 55, "the user's rate and the power policy cap it")
        XCTAssertEqual(Video.frameRate(videoRate: 0, refresh: 60, limit: 60), 60, "unknown: the display's paced rate")
    }

    func testTheDecoderHandsFramesAtThePlacedSize() {
        XCTAssertEqual(Video.decodedPixels(video: SIMD2(3840, 2160), ring: SIMD2(1920, 1080), placement: .fill), SIMD2(1920, 1080))
        XCTAssertEqual(Video.decodedPixels(video: SIMD2(1920, 1080), ring: SIMD2(1920, 1080), placement: .fill), SIMD2(1920, 1080))
        XCTAssertEqual(Video.decodedPixels(video: SIMD2(3840, 2160), ring: SIMD2(1920, 1200), placement: .fit), SIMD2(1920, 1080))
        XCTAssertEqual(Video.decodedPixels(video: SIMD2(1280, 720), ring: SIMD2(1920, 1080), placement: .fill), SIMD2(1280, 720),
                       "never above the video's own")
    }

    func testTheQuadFollowsThePlacement() {
        XCTAssertEqual(VideoFrameDrawer.quad(frame: SIMD2(16, 9), target: SIMD2(16, 9), placement: .fill), SIMD4(-1, -1, 1, 1))
        XCTAssertEqual(VideoFrameDrawer.quad(frame: SIMD2(16, 9), target: SIMD2(16, 18), placement: .fit), SIMD4(-1, -0.5, 1, 0.5))
        XCTAssertEqual(VideoFrameDrawer.quad(frame: SIMD2(16, 9), target: SIMD2(16, 18), placement: .stretch), SIMD4(-1, -1, 1, 1))
        let fill = VideoFrameDrawer.quad(frame: SIMD2(16, 9), target: SIMD2(16, 18), placement: .fill)
        XCTAssertEqual(fill.y, -1)
        XCTAssertLessThan(fill.x, -1, "filled: the sides are cropped")
    }

    func testAFittedFrameIsDrawnBetweenBlackBars() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let drawer = try XCTUnwrap(VideoFrameDrawer(device: device))
        let publisher = try publisher(ring: SIMD2(8, 8))
        var made: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferMetalCompatibilityKey as String: true,
                                         kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        XCTAssertEqual(CVPixelBufferCreate(nil, 8, 4, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &made), kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)), 0xFF, CVPixelBufferGetBytesPerRow(buffer) * 4)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        XCTAssertTrue(drawer.draw(buffer, ring: 0, placement: .fit, publisher: publisher))
        let deadline = Date().addingTimeInterval(5)
        while publisher.newestImage(ring: 0) == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(try pixel(publisher, x: 4, y: 0), SIMD3(0, 0, 0), "the bar above")
        XCTAssertEqual(try pixel(publisher, x: 4, y: 4), SIMD3(255, 255, 255), "the frame")
        XCTAssertEqual(try pixel(publisher, x: 4, y: 7), SIMD3(0, 0, 0), "the bar below")
    }

    // MARK: - Live frames

    func testAPlayerOfItsOwnPublishesTheVideosFrames() throws {
        let clip = try VideoClipFixture.make(frames: 60, fps: 30, in: root)
        let publisher = try publisher(ring: SIMD2(64, 64))
        let video = try XCTUnwrap(Video(url: clip, name: "clip", ring: 0, pixels: SIMD2(64, 64), frameRate: 30, rate: 1,
                                        placement: .fill, screen: NSScreen.main, sharing: nil, publisher: publisher))
        defer { video.shutdown() }
        XCTAssertFalse(video.sharesDesktopPlayer)
        XCTAssertGreaterThanOrEqual(waitForFrames(publisher, count: 10), 10, "the decoded frames reach the ring")
        let image = try XCTUnwrap(publisher.newestImage(ring: 0))
        XCTAssertEqual(image.width, 64)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        XCTAssertEqual(files, ["clip.mov"], "nothing is linked or copied")
    }

    func testTheDesktopsPlayerIsDrawnFromAndGivenBack() throws {
        let clip = try VideoClipFixture.make(frames: 60, fps: 30, in: root)
        let player = WallpaperAVPlayer.make(item: AVPlayerItem(url: clip))
        player.isMuted = true
        let desktop = DesktopPlayer(player)
        let publisher = try publisher(ring: SIMD2(64, 64))
        let video = try XCTUnwrap(Video(url: clip, name: "clip", ring: 0, pixels: SIMD2(64, 64), frameRate: 30, rate: 1,
                                        placement: .fill, screen: NSScreen.main, sharing: desktop, publisher: publisher))
        XCTAssertTrue(video.sharesDesktopPlayer)
        XCTAssertEqual(desktop.holds, [true], "held playing for the screen saver")
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(item.outputs.count, 1, "its frames are read from the desktop's own item: no second decoder")
        XCTAssertGreaterThanOrEqual(waitForFrames(publisher, count: 10), 10)

        // The desktop switches its item (another wallpaper, a repair): the frames follow it.
        let next = AVPlayerItem(url: clip)
        player.replaceCurrentItem(with: next)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(item.outputs.isEmpty)
        XCTAssertEqual(next.outputs.count, 1)

        video.shutdown()
        XCTAssertEqual(desktop.holds, [true, false], "given back to its own rules")
        XCTAssertTrue(next.outputs.isEmpty)
        XCTAssertNotNil(player.currentItem, "the desktop keeps its video")
    }
}
