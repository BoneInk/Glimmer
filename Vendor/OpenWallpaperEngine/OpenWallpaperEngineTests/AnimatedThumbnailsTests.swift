import AppKit
import ImageIO
import XCTest
@testable import OpenWallpaperEngine

/// Animated library previews are built in and always on: no Plugins entry or preference, the
/// retired key is dropped, tiles play by default, and Low Power Mode plays only on hover.
@MainActor
final class AnimatedThumbnailsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "owe-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "OpenWallpaperEngine")

    /// The Plugins page, its search entries and Restore Defaults no longer know the plugin.
    func testPluginsPageNoLongerListsIt() throws {
        let page = try String(contentsOf: Self.sources.appending(path: "Settings/PluginsPage.swift"), encoding: .utf8)
        XCTAssertFalse(page.contains("Animated Thumbnails"))
        XCTAssertFalse(page.contains(ThumbnailAnimation.retiredPreferenceKey))
        XCTAssertTrue(SettingsSearch.results(for: "Animated Thumbnails", locale: Locale(identifier: "en")).isEmpty)
        XCTAssertFalse(SettingsTabReset.allPreferenceKeys.contains(ThumbnailAnimation.retiredPreferenceKey))
        XCTAssertFalse(SettingsTransfer.preferenceKeys.contains(ThumbnailAnimation.retiredPreferenceKey))
        XCTAssertFalse(SettingsTabReset.hasChanges(.plugins, settings: GlobalSettings(), defaults: defaults))
    }

    /// A stored "off" is removed at launch, and a settings file that still carries it imports
    /// without it.
    func testRetiredKeyIsMigratedAndIgnored() throws {
        defaults.set(false, forKey: ThumbnailAnimation.retiredPreferenceKey)
        ThumbnailAnimation.removeRetiredPreference(from: defaults)
        XCTAssertNil(defaults.object(forKey: ThumbnailAnimation.retiredPreferenceKey))

        var old = SettingsTransfer.export(settings: GlobalSettings(), defaults: defaults, updates: nil, appVersion: "1")
        old.preferences = [ThumbnailAnimation.retiredPreferenceKey: false, "ReclaimOriginalPackages": true]
        let imported = try SettingsTransfer.decode(old.encoded())
        XCTAssertEqual(imported.preferences, ["ReclaimOriginalPackages": true])
        imported.applyPreferences(to: defaults)
        XCTAssertNil(defaults.object(forKey: ThumbnailAnimation.retiredPreferenceKey))
    }

    /// Tiles play by default, with nothing stored; not while the app is in the background.
    func testThumbnailsAnimateByDefault() {
        XCTAssertNil(defaults.object(forKey: ThumbnailAnimation.retiredPreferenceKey))
        XCTAssertTrue(ThumbnailAnimation.plays(isAppActive: true, isLowPowerMode: false, isHovered: false))
        XCTAssertFalse(ThumbnailAnimation.plays(isAppActive: false, isLowPowerMode: false, isHovered: true))
    }

    /// In Low Power Mode a tile plays only while hovered.
    func testLowPowerModePlaysOnHoverOnly() {
        XCTAssertFalse(ThumbnailAnimation.plays(isAppActive: true, isLowPowerMode: true, isHovered: false))
        XCTAssertTrue(ThumbnailAnimation.plays(isAppActive: true, isLowPowerMode: true, isHovered: true))
    }

    /// Low Power Mode is followed as it changes.
    func testLowPowerModeStateFollowsTheSystem() {
        var enabled = false
        let center = NotificationCenter()
        let state = LowPowerModeState(read: { enabled }, center: center)
        XCTAssertFalse(state.isEnabled)
        enabled = true
        center.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        XCTAssertTrue(state.isEnabled)
    }

    /// A preview in a window that isn't on screen stands still, however it's asked to play.
    func testPreviewPausesWhileItsWindowIsHidden() {
        XCTAssertFalse(ThumbnailAnimation.windowShows(nil))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = PreviewImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        view.wantsAnimation = true
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(ThumbnailAnimation.windowShows(window))
        XCTAssertFalse(view.isAnimating)
        view.wantsAnimation = false
        XCTAssertFalse(view.isAnimating)
    }

    /// A preview in a window that isn't on screen never joins the shared animator, so offscreen
    /// tiles cost no decoding and no commits.
    func testOffscreenPreviewDoesNotJoinTheAnimator() throws {
        let before = PreviewAnimator.shared.playingCount
        let view = PreviewImageView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.animationURL = try Self.makeGIF(frames: 3, size: 64)
        view.wantsAnimation = true
        XCTAssertFalse(view.isAnimating)
        XCTAssertEqual(PreviewAnimator.shared.playingCount, before)
    }

    /// Frames are decoded at the size the tile shows them: a large GIF is scaled down to fill
    /// (or fit) the tile's pixels, a small one is never scaled up.
    func testFramesAreDecodedAtTheTileSize() throws {
        let tile = CGSize(width: 400, height: 400)
        XCTAssertEqual(PreviewFrameSequence.decodedSize(of: CGSize(width: 800, height: 450), shownIn: tile, fills: true),
                       CGSize(width: 711, height: 400))
        XCTAssertEqual(PreviewFrameSequence.decodedSize(of: CGSize(width: 800, height: 450), shownIn: tile, fills: false),
                       CGSize(width: 400, height: 225))
        XCTAssertEqual(PreviewFrameSequence.decodedSize(of: CGSize(width: 256, height: 256), shownIn: tile, fills: true),
                       CGSize(width: 256, height: 256))

        let url = try Self.makeGIF(frames: 4, size: 600)
        let sequence = try XCTUnwrap(PreviewFrameSequence(url: url, fitting: CGSize(width: 200, height: 200), fills: true))
        XCTAssertEqual(sequence.frameCount, 4)
        XCTAssertEqual(sequence.pixelSize, CGSize(width: 200, height: 200))
        let frame = try XCTUnwrap(sequence.decode(2))
        XCTAssertEqual(frame.width, 200)
        XCTAssertEqual(frame.height, 200)
        XCTAssertTrue(sequence.keepsFrames)
    }

    /// Frames follow the GIF's delays and loop; a delay under 11 ms shows as 100 ms, as browsers do.
    func testFrameIndexFollowsTheDelays() throws {
        let sequence = try XCTUnwrap(PreviewFrameSequence(url: try Self.makeGIF(frames: 3, size: 32, delay: 0.05),
                                                          fitting: CGSize(width: 32, height: 32), fills: true))
        XCTAssertEqual(sequence.frameIndex(at: 0), 0)
        XCTAssertEqual(sequence.frameIndex(at: 0.06), 1)
        XCTAssertEqual(sequence.frameIndex(at: 0.12), 2)
        XCTAssertEqual(sequence.frameIndex(at: 0.16), 0)
        let fast = try XCTUnwrap(PreviewFrameSequence(url: try Self.makeGIF(frames: 2, size: 32, delay: 0),
                                                      fitting: CGSize(width: 32, height: 32), fills: true))
        XCTAssertEqual(fast.delays, [0.1, 0.1])
    }

    /// A GIF of `frames` solid frames, `size` pixels square.
    private static func makeGIF(frames: Int, size: Int, delay: Double = 0.04) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "owe-preview-\(UUID().uuidString).gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames, nil))
        for index in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(frames), green: 0.5, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
