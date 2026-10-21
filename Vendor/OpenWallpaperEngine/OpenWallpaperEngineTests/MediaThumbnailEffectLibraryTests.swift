import XCTest
import simd
@testable import OpenWallpaperEngine

/// `$mediaThumbnail` / `$mediaPreviousThumbnail` bound by `usertextures` in effect and material
/// passes, through the real loader and renderer with a song injected into the media session.
/// 2963872291's album-art layers are placeholder images whose material binds `$mediaThumbnail` to
/// slot 0, and whose Blend Gradient pass binds `$mediaPreviousThumbnail` (slot 1, the blend
/// texture) and `$mediaThumbnail` (slot 2, the gradient) over the authored placeholder. Skipped
/// without the items (`OWE_LIBRARY`). With `OWE_GROUND_TRUTH_OUT` set, the frames are written there.
final class MediaThumbnailEffectLibraryTests: XCTestCase {
    private static var library: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage")
    }

    private static var out: URL? {
        ProcessInfo.processInfo.environment["OWE_GROUND_TRUTH_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    private func harness(_ id: String, media: SceneScriptReplayMediaSource) throws -> ModelSceneHarness {
        let directory = Self.library.appending(path: id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.appending(path: "project.json").path) else {
            throw XCTSkip("\(id) isn't in the library")
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

    private func frame(_ harness: ModelSceneHarness, _ name: String) throws -> [UInt8] {
        let pixels = try ModelGroundTruthLibraryTests.frame1080(harness)
        if let out = Self.out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try WEReferenceImage(width: 1920, height: 1080, pixels: pixels).write(to: out.appending(path: "\(name).png"))
        }
        return pixels
    }

    private static func colour(_ frame: [UInt8], _ x: Int, _ y: Int) -> SIMD3<Int> {
        let index: Int = (y * 1920 + x) * 4
        return SIMD3<Int>(Int(frame[index]), Int(frame[index + 1]), Int(frame[index + 2]))
    }

    /// Asserts the quadrants of the artwork around `centre` (frame pixels, rows top-down), `offset` in.
    private static func assertQuadrants(_ frame: [UInt8], centre: SIMD2<Int>, offset: Int, _ label: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let topLeft = colour(frame, centre.x - offset, centre.y - offset)
        let topRight = colour(frame, centre.x + offset, centre.y - offset)
        let bottomLeft = colour(frame, centre.x - offset, centre.y + offset)
        let bottomRight = colour(frame, centre.x + offset, centre.y + offset)
        let red = topLeft.x > 180 && topLeft.y < 70 && topLeft.z < 70
        let green = topRight.y > 180 && topRight.x < 70 && topRight.z < 70
        let blue = bottomLeft.z > 180 && bottomLeft.x < 70 && bottomLeft.y < 70
        let white = bottomRight.x > 180 && bottomRight.y > 180 && bottomRight.z > 180
        XCTAssertTrue(red, "\(label): top left is red: \(topLeft)", file: file, line: line)
        XCTAssertTrue(green, "\(label): top right is green: \(topRight)", file: file, line: line)
        XCTAssertTrue(blue, "\(label): bottom left is blue: \(bottomLeft)", file: file, line: line)
        XCTAssertTrue(white, "\(label): bottom right is white: \(bottomRight)", file: file, line: line)
    }

    /// 2963872291's small album cover (object 386, 512 × 0.72631 ≈ 372 scene pixels at
    /// (3607.1, 228.9) of the 3840 × 2160 scene: 186 pixels centred at (1804, 966) in the 1920 × 1080
    /// frame) shows the artwork upright: its material's slot 0 and its Blend Gradient's slots 1–2
    /// all take it. Before the artwork arrives, it shows the authored placeholder instead.
    func testTheAlbumCoverShowsTheArtworkThroughItsEffect() throws {
        let media = SceneScriptReplayMediaSource()
        let harness = try harness("2963872291", media: media)
        media.send(Self.song(artwork: nil))
        for _ in 0..<120 { harness.frame() }
        let before = try frame(harness, "2963872291-no-artwork")
        let placeholder = Self.colour(before, 1759, 921)
        let noRed = !(placeholder.x > 180 && placeholder.y < 70)
        XCTAssertTrue(noRed, "without artwork the cover keeps its placeholder: \(placeholder)")

        media.send(Self.song(artwork: try MediaThumbnailLibraryTests.quadrantPNG()))
        for _ in 0..<180 { harness.frame() }
        let after = try frame(harness, "2963872291-artwork")
        Self.assertQuadrants(after, centre: SIMD2(1804, 966), offset: 45, "2963872291 cover")
    }

    /// 3109042108's album art (object 657, a solid layer) gets the artwork only through its Blend
    /// effect's slot 1 (`$mediaThumbnail` over the authored `500x500`): about 60 frame pixels
    /// centred at (1512, 934), upright. Without artwork, the slot keeps the authored texture.
    func testTheAlbumArtShowsTheArtworkThroughItsBlendEffect() throws {
        let media = SceneScriptReplayMediaSource()
        let harness = try harness("3109042108", media: media)
        media.send(Self.song(artwork: nil))
        for _ in 0..<120 { harness.frame() }
        let before = try frame(harness, "3109042108-no-artwork")
        let authored = Self.colour(before, 1497, 919)
        let noRed = !(authored.x > 180 && authored.y < 70)
        XCTAssertTrue(noRed, "without artwork the blend keeps its authored texture: \(authored)")

        media.send(Self.song(artwork: try MediaThumbnailLibraryTests.quadrantPNG()))
        for _ in 0..<180 { harness.frame() }
        let after = try frame(harness, "3109042108-artwork")
        Self.assertQuadrants(after, centre: SIMD2(1512, 934), offset: 15, "3109042108 album art")
    }

    /// `usertextures` bind slot by slot, the pass's (or `instance`'s) over the material's; a user
    /// property's texture (a plain string) and a name this app doesn't supply bind nothing.
    func testUserTexturesBindSlotBySlot() throws {
        let pass = try JSONDecoder().decode(SceneJSON.self, from: Data(#"[null, {"name": "$mediaPreviousThumbnail", "type": "system"}, "newproperty", {"name": "$unknown", "type": "system"}]"#.utf8))
        let material = try JSONDecoder().decode(SceneJSON.self, from: Data(#"[{"name": "$mediaThumbnail", "type": "system"}, {"name": "$mediaThumbnail", "type": "system"}]"#.utf8))
        let bindings: [Int: SceneSystemTexture] = SceneSystemTexture.bindings(in: [pass, material], owner: "test")
        XCTAssertEqual(bindings, [0: .mediaThumbnail, 1: .mediaPreviousThumbnail])
    }
}
