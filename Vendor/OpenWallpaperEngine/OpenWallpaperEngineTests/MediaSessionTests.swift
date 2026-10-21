import CoreGraphics
import XCTest
@testable import OpenWallpaperEngine

/// The media state model, MediaRemote's dictionary mapping and WE's artwork palette
/// (`winrtutil64.exe`).
final class MediaSessionTests: XCTestCase {
    // MARK: - State

    func testChangesComeInWEsCallbackOrder() {
        var state = MediaSessionState()
        state.enabled = true
        state.timeline.duration = 100
        state.properties.title = "Song"
        state.playback = .playing
        XCTAssertEqual(state.changes(since: MediaSessionState()), [
            .status(true), .playback(.playing), .properties(state.properties), .timeline(state.timeline),
        ])
        XCTAssertEqual(state.changes(since: state), [])
    }

    func testInitialStateSkipsEmptyParts() {
        var state = MediaSessionState()
        XCTAssertEqual(state.initialChanges, [], "disabled, stopped, untitled, no artwork, no duration")
        state.enabled = true
        state.properties.artist = "Artist"
        state.timeline.position = 5
        XCTAssertEqual(state.initialChanges, [.status(true)], "properties need a title; a timeline needs a duration")
    }

    // MARK: - MediaRemote mapping

    func testNowPlayingDictionaryMapsToWEsFields() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let info: [String: Any] = [
            MediaRemote.Key.title: "Song", MediaRemote.Key.artist: "Artist", MediaRemote.Key.album: "Album",
            MediaRemote.Key.genre: "Pop", MediaRemote.Key.mediaType: "MRMediaRemoteMediaTypeMusic",
            MediaRemote.Key.duration: 200.0, MediaRemote.Key.elapsedTime: 10.0,
            MediaRemote.Key.timestamp: now.addingTimeInterval(-4.5), MediaRemote.Key.playbackRate: 1.0,
        ]
        let state = MacMediaSessionSource.state(from: info, isPlaying: false, enabled: true, now: now, artwork: nil)
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.playback, .playing, "a positive playback rate is playing")
        XCTAssertEqual(state.properties, .init(title: "Song", artist: "Artist", albumTitle: "Album", genres: "Pop",
                                               contentType: "music"))
        XCTAssertEqual(state.timeline, .init(position: 14, duration: 200), "elapsed + time since the timestamp")
        XCTAssertFalse(state.thumbnail.hasThumbnail)

        var pausedInfo = info
        pausedInfo[MediaRemote.Key.playbackRate] = 0.0
        let paused = MacMediaSessionSource.state(from: pausedInfo, isPlaying: false, enabled: true, now: now, artwork: nil)
        XCTAssertEqual(paused.playback, .paused)
        XCTAssertEqual(paused.timeline.position, 10)
        XCTAssertEqual(MacMediaSessionSource.state(from: [:], isPlaying: false, enabled: true, now: now, artwork: nil).playback,
                       .stopped)
    }

    // MARK: - Artwork palette

    /// An image of horizontal stripes, `rows` rows of each colour.
    private func stripes(_ colors: [(r: UInt8, g: UInt8, b: UInt8, rows: Int)], width: Int = 8) -> [UInt8] {
        var pixels: [UInt8] = []
        for color in colors {
            for _ in 0..<(color.rows * width) { pixels += [color.r, color.g, color.b, 255] }
        }
        return pixels
    }

    func testPrimarySecondaryTertiaryAndContrastChoices() {
        let pixels = stripes([(255, 0, 0, 7), (0, 0, 255, 2), (0, 255, 0, 1)])
        let colors = ArtworkPalette.colors(rgba: pixels, width: 8, height: 10)
        XCTAssertEqual(colors.primary, SIMD3(1, 0, 0), "the highest score")
        XCTAssertEqual(colors.secondary, SIMD3(0, 0, 1), "blue and green are equally far from red; blue scores more")
        XCTAssertEqual(colors.tertiary, SIMD3(0, 1, 0), "far from both")
        XCTAssertEqual(colors.highContrast, .zero, "red on black is 5.25:1")
        XCTAssertEqual(colors.text, SIMD3(0, 1, 0), "red/blue is 2.15:1, red/green 2.91:1")
    }

    func testDistanceOutweighsAreaForTheSecondaryColour() {
        // Orange (30°) is next to red, so a smaller cyan (180°) area wins secondary.
        let pixels = stripes([(255, 0, 0, 10), (255, 128, 0, 6), (0, 255, 255, 3)])
        let colors = ArtworkPalette.colors(rgba: pixels, width: 8, height: 19)
        XCTAssertEqual(colors.secondary, SIMD3(0, 1, 1))
    }

    func testGreyArtworkIsBlackWithWhiteContrast() {
        let pixels = stripes([(128, 128, 128, 4)])
        let colors = ArtworkPalette.colors(rgba: pixels, width: 8, height: 4)
        XCTAssertEqual(colors.primary, .zero, "grey scores 0, so no bin wins")
        XCTAssertEqual(colors.highContrast, SIMD3(1, 1, 1))
        XCTAssertEqual(colors.text, SIMD3(1, 1, 1))
    }

    func testMeanSaturationAndValueAndTransparentPixels() {
        // Two reds of one hue bin: full and half value, averaged. Transparent pixels don't count.
        var pixels = stripes([(255, 0, 0, 1), (128, 0, 0, 1)], width: 1)
        pixels += [0, 255, 0, 10]
        let colors = ArtworkPalette.colors(rgba: pixels, width: 1, height: 3)
        XCTAssertEqual(colors.primary.x, Float(Int((1 + 128.0 / 255) / 2 * 255)) / 255, accuracy: 1e-6)
        XCTAssertEqual(colors.secondary, .zero, "the green pixel has alpha 10 < 16")
    }

    func testCGImageInput() throws {
        let pixels = stripes([(0, 0, 255, 4)])
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 8, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(ArtworkPalette.colors(of: image)?.primary, SIMD3(0, 0, 1))
    }

    func testContrastRatioIsWCAG() {
        XCTAssertEqual(ArtworkPalette.contrastRatio(SIMD3(1, 1, 1), .zero), 21, accuracy: 1e-4)
        XCTAssertEqual(ArtworkPalette.contrastRatio(SIMD3(1, 0, 0), .zero), 5.252, accuracy: 1e-3)
    }
}
