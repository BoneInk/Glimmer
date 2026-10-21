import XCTest
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import OpenWallpaperEngine

/// 3546971487 ("Sakura") through the real loader and renderer with a song injected into its media
/// session: its Media Area (object 47) holds the song title (50) and artist (51), set by
/// `mediaPropertiesChanged`, and the album cover (57), a solid layer whose `instance` binds
/// `$mediaThumbnail` to its image. Skipped without the item (`OWE_LIBRARY`). With
/// `OWE_GROUND_TRUTH_OUT` set, the frames are written there.
final class MediaThumbnailLibraryTests: XCTestCase {
    private static var library: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage")
    }

    private static var out: URL? {
        ProcessInfo.processInfo.environment["OWE_GROUND_TRUTH_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func harness(media: SceneScriptReplayMediaSource) throws -> ModelSceneHarness {
        let directory = Self.library.appending(path: "3546971487", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path) else {
            throw XCTSkip("3546971487 isn't in the library")
        }
        let storage = FileManager.default.temporaryDirectory.appending(path: "owe-media-\(UUID().uuidString)")
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: storage.path) {
                do { try FileManager.default.removeItem(at: storage) } catch { XCTFail("\(storage.path): \(error)") }
            }
        }
        let harness = try ModelSceneHarness(directory: directory, settings: SceneRenderSettings(), size: SIMD2(1920, 1080),
                                            storage: storage, media: media)
        addTeardownBlock { harness.close() }
        try harness.settle(seconds: 20)
        return harness
    }

    /// A song playing, with `artwork` as its thumbnail.
    private static func song(artwork: Data?) -> MediaSessionState {
        var state = MediaSessionState()
        state.enabled = true
        state.playback = .playing
        state.properties = .init(title: "Too Sweet", artist: "Hozier", albumTitle: "Unheard", contentType: "music")
        if let artwork {
            let colors = ArtworkPalette.Colors(primary: SIMD3<Float>(0.8, 0.2, 0.1), secondary: SIMD3<Float>(0.1, 0.3, 0.7),
                                               tertiary: SIMD3<Float>(0.9, 0.9, 0.2), text: SIMD3<Float>(1, 1, 1),
                                               highContrast: SIMD3<Float>(0, 0, 0))
            state.thumbnail = .init(artwork: artwork.hashValue, colors: colors, png: artwork)
        }
        return state
    }

    /// A 64 × 64 PNG in quadrants, rows top-down: red top left, green top right, blue bottom left,
    /// white bottom right.
    static func quadrantPNG() throws -> Data {
        let size = 64
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let colour: [UInt8]
                switch (y < size / 2, x < size / 2) {
                case (true, true): colour = [255, 0, 0]
                case (true, false): colour = [0, 255, 0]
                case (false, true): colour = [0, 0, 255]
                case (false, false): colour = [255, 255, 255]
                }
                let index: Int = (y * size + x) * 4
                bytes[index] = colour[0]
                bytes[index + 1] = colour[1]
                bytes[index + 2] = colour[2]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func write(_ harness: ModelSceneHarness, _ name: String) throws {
        guard let out = Self.out else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pixels = try ModelGroundTruthLibraryTests.frame1080(harness)
        try WEReferenceImage(width: 1920, height: 1080, pixels: pixels).write(to: out.appending(path: "\(name).png"))
    }

    /// The Media Area's "Init Media Area" is a `startpaused` relative scale whose first key is
    /// −0.51679 on y: it holds 0.35984 − 0.51679 = −0.157, upside down, as WE holds a paused
    /// timeline's first key (docs/timeline-plan.md §2.6), until `mediaThumbnailChanged` plays it.
    /// The title and artist, its children, stand upright once the song's artwork arrived; a title
    /// alone doesn't play it.
    func testTheSongTitleStandsUprightOnceTheArtworkArrives() throws {
        let media = SceneScriptReplayMediaSource()
        let harness = try harness(media: media)
        let probe = SceneDrawProbe()
        harness.renderer.drawProbe = probe
        for _ in 0..<10 { harness.frame() }
        let paused: Float = try XCTUnwrap(probe.layers["47"]).local.scale.y
        XCTAssertEqual(paused, 0.35984 - 0.51679, accuracy: 1e-4, "the paused timeline holds its first key")

        media.send(Self.song(artwork: nil))
        for _ in 0..<60 { harness.frame() }
        try write(harness, "sakura-title-without-artwork")
        let titled: Float = try XCTUnwrap(probe.layers["47"]).local.scale.y
        XCTAssertLessThan(titled, 0, "mediaPropertiesChanged doesn't play the Media Area's timeline")

        media.send(Self.song(artwork: try Self.quadrantPNG()))
        for _ in 0..<60 { harness.frame() }
        try write(harness, "sakura-title-with-artwork")
        let upright: Float = try XCTUnwrap(probe.layers["47"]).local.scale.y
        XCTAssertEqual(upright, 0.35984, accuracy: 1e-4, "mediaThumbnailChanged played it to its last key")
        for id in ["50", "51"] {
            let scale: Float = try XCTUnwrap(probe.layers[id], "layer \(id) draws").local.scale.y
            XCTAssertGreaterThan(scale, 0, "layer \(id)")
        }
    }

    /// The album cover shows the song's artwork (`$mediaThumbnail`) the way up the artwork is: red
    /// at its top left, green top right, blue bottom left. It is 350 × 1.884 × 0.35984 ≈ 237 scene
    /// pixels on a side, centred at (3098.6, 912.4) of the 3840 × 2160 scene: (1549, 624) and 118
    /// pixels in the 1920 × 1080 frame (rows top-down).
    func testTheAlbumCoverShowsTheArtworkUpright() throws {
        let media = SceneScriptReplayMediaSource()
        let harness = try harness(media: media)
        media.send(Self.song(artwork: try Self.quadrantPNG()))
        for _ in 0..<60 { harness.frame() }
        try write(harness, "sakura-album-cover")
        let frame = try ModelGroundTruthLibraryTests.frame1080(harness)
        func colour(_ x: Int, _ y: Int) -> SIMD3<Int> {
            let index: Int = (y * 1920 + x) * 4
            return SIMD3<Int>(Int(frame[index]), Int(frame[index + 1]), Int(frame[index + 2]))
        }
        let centre = SIMD2<Int>(1549, 624)
        let offset = 30
        let topLeft = colour(centre.x - offset, centre.y - offset)
        let topRight = colour(centre.x + offset, centre.y - offset)
        let bottomLeft = colour(centre.x - offset, centre.y + offset)
        XCTAssertTrue(topLeft.x > 200 && topLeft.y < 60 && topLeft.z < 60, "top left is red: \(topLeft)")
        XCTAssertTrue(topRight.y > 200 && topRight.x < 60 && topRight.z < 60, "top right is green: \(topRight)")
        XCTAssertTrue(bottomLeft.z > 200 && bottomLeft.x < 60 && bottomLeft.y < 60, "bottom left is blue: \(bottomLeft)")
    }
}
