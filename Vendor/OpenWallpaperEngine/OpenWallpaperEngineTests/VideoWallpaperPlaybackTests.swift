import AVFoundation
import Metal
import XCTest
@testable import OpenWallpaperEngine

/// Video wallpapers keep playing the way WE's do: they loop, and never hold the display awake.
@MainActor
final class VideoWallpaperPlaybackTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appending(path: "owe-video-tests-\(UUID().uuidString)")
    }

    override func tearDown() {
        if let directory { try? FileManager.default.trashItem(at: directory, resultingItemURL: nil) } // Optional: best-effort cleanup.
        super.tearDown()
    }

    private func wallpaper(_ clip: URL) -> WEWallpaper {
        WEWallpaper(using: WEProject(file: clip.lastPathComponent, preview: "p.jpg", title: "clip", type: "video"),
                    where: clip.deletingLastPathComponent())
    }

    /// V1: a playing AVPlayer takes a `PreventUserIdleDisplaySleep` assertion unless told not to.
    func testWallpaperPlayersLetTheDisplaySleep() throws {
        let clip = try VideoClipFixture.make(frames: 10, in: directory)
        let factoryPlayer: AVPlayer = WallpaperAVPlayer.make()
        XCTAssertFalse(factoryPlayer.preventsDisplaySleepDuringVideoPlayback)

        let wallpapers = WallpaperViewModel(persistsWallpapers: false)
        wallpapers.audioOutputEnabled = false
        let model = VideoWallpaperViewModel(wallpaper: wallpaper(clip), wallpaperViewModel: wallpapers)
        XCTAssertFalse(model.player.preventsDisplaySleepDuringVideoPlayback, "AVKit path")
        model.stop()

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stream = try XCTUnwrap(VideoTextureStream(url: clip, device: device))
        XCTAssertFalse(stream.player.preventsDisplaySleepDuringVideoPlayback, "Metal path")
        stream.stop()
    }

    /// V9: a short clip played past its end keeps playing from the start.
    func testAVKitVideoLoopsPastItsEnd() throws {
        let clip = try VideoClipFixture.make(frames: 10, in: directory) // 1/3 s
        let wallpapers = WallpaperViewModel(persistsWallpapers: false)
        wallpapers.audioOutputEnabled = false
        let model = VideoWallpaperViewModel(wallpaper: wallpaper(clip), wallpaperViewModel: wallpapers)
        defer { model.stop() }
        XCTAssertEqual(model.player.actionAtItemEnd, .none)
        var ended = 0
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: model.player.currentItem, queue: .main) { _ in ended += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let deadline = Date().addingTimeInterval(5)
        while ended < 2, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertGreaterThanOrEqual(ended, 2, "the clip reached its end a second time")
        let rate: Float = model.player.rate
        XCTAssertGreaterThan(rate, 0)
    }
}
