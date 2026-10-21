import CryptoKit
import XCTest
@testable import OpenWallpaperEngine

/// The `TEXS` block of animated `.tex` files (docs/timeline-plan.md §1.2): every version, every
/// frame kept (0 s ones included), and the library's animated textures.
final class TEXSpriteFramesTests: XCTestCase {
    private struct Frame {
        var image: UInt32 = 0
        var time: Float
        var rect: [Float] = [0, 0, 2, 0, 0, 1]
    }

    private static func block(_ version: Character, _ frames: [Frame]) -> [UInt8] {
        var bytes = Array("TEXS000\(version)\u{0}".utf8)
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { bytes += $0 } }
        u32(UInt32(frames.count))
        if version == "3" { u32(64); u32(32) }
        for frame in frames {
            u32(frame.image)
            u32(frame.time.bitPattern)
            for value in frame.rect {
                u32(version == "1" ? UInt32(bitPattern: Int32(value)) : value.bitPattern)
            }
        }
        return bytes
    }

    func testEveryVersionParsesToTheSameFrames() throws {
        let frames = [Frame(time: 0.25, rect: [1, 2, 3, 0, 0, 4]), Frame(image: 1, time: 0, rect: [5, 6, 7, 1, 1, 8])]
        for version: Character in ["1", "2", "3"] {
            let bytes = Array("TEXV0005\u{0}".utf8) + Self.block(version, frames)
            let parsed = try XCTUnwrap(TEXSpriteFrames.frames(bytes), "TEXS000\(version)")
            XCTAssertEqual(parsed.map(\.duration), [0.25, 0], "the 0 s frame is kept (TEXS000\(version))")
            XCTAssertEqual(parsed.map(\.imageIndex), [0, 1])
            XCTAssertEqual([parsed[1].x, parsed[1].y, parsed[1].width, parsed[1].widthY, parsed[1].heightX, parsed[1].height],
                           [5, 6, 7, 1, 1, 8])
            XCTAssertEqual(TEXSpriteFrames.durations(bytes), [0.25, 0])
        }
    }

    func testTruncatedAndMissingBlocksAreNil() {
        let bytes = Array("TEXV0005\u{0}".utf8) + Self.block("3", [Frame(time: 0.1), Frame(time: 0.2)])
        XCTAssertNil(TEXSpriteFrames.frames(Array(bytes.dropLast(4))))
        XCTAssertNil(TEXSpriteFrames.frames(Array("TEXV0005\u{0}".utf8)))
        var cursor = 0
        XCTAssertNil(TEXSpriteFrames.parse(bytes, cursor: &cursor), "no block at the cursor")
        XCTAssertEqual(cursor, 0)
    }

    /// The decoder keeps 0 s frames too; it drops only frames it can't draw.
    func testAnimatedImagesKeepZeroSecondFrames() throws {
        var data = TextureRG88Tests.tex(format: 1, width: 2, height: 1, pixels: [255, 0, 0, 0, 255, 0])
        let frames = [Frame(time: 0.1), Frame(time: 0), Frame(time: 0.2), Frame(time: 0.1, rect: [0, 0, 0, 0, 0, 1])]
        data.append(contentsOf: Self.block("3", frames))
        let animation = try XCTUnwrap(TEXParser(data: data).extractAnimatedImages())
        XCTAssertEqual(animation.images.count, 1)
        XCTAssertEqual(animation.frames.map(\.duration), [0.1, 0, 0.2], "the frame without area is dropped")
    }

    // MARK: - Library

    private struct LibraryTexture: Decodable {
        let root: String
        let item: String
        let file: String
        let version: String
        let frameCount: Int
        let frameTimes: [Float]
        let duration: Float
        /// The SHA-256 of the texture's bytes when the fixture was written.
        let sha256: String

        var key: String { "\(root) \(item) \(file)" }
    }

    private static var roots: [String: URL] {
        let environment = ProcessInfo.processInfo.environment
        let workshop = environment["OWE_WORKSHOP"]
            ?? "/Volumes/980Pro/Crossover/bottles/Steam Bottle/drive_c/Program Files (x86)/Steam/steamapps/workshop/content/431960"
        return ["storage": URL(fileURLWithPath: environment["OWE_LIBRARY"] ?? "/Volumes/980Pro/OpenWallpaperStorage"),
                "workshop": URL(fileURLWithPath: workshop)]
    }

    private func bytes(of texture: LibraryTexture) throws -> Data? {
        guard let root = Self.roots[texture.root] else { return nil }
        let item = root.appending(path: texture.item, directoryHint: .isDirectory)
        let parts = texture.file.components(separatedBy: "::")
        let file = item.appending(path: parts[0])
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard parts.count == 2 else { return try Data(contentsOf: file) }
        return try PKGParser(url: file).extractFile(named: parts[1])
    }

    private func check(_ data: Data, _ texture: LibraryTexture) throws {
        let label = "\(texture.item) \(texture.file)"
        let frames = try XCTUnwrap(TEXSpriteFrames.frames(Array(data)), label)
        XCTAssertEqual(frames.count, texture.frameCount, label)
        XCTAssertEqual(frames.map(\.duration), texture.frameTimes, label)
        XCTAssertEqual(SceneTextureAnimationClock(frames: frames).duration, texture.duration, label)
    }

    /// Every animated `.tex` of the library (`Tests/Fixtures/Library/texs-frames.json`, from
    /// `Scripts/texs-frames.py`, a reader of its own): its frame count and frame times, in float,
    /// 0 s frames included, and the duration they sum to. A texture the fixture lists is checked
    /// against it while its bytes are the ones it read. The library keeps gaining and updating
    /// wallpapers: the script is run now to find the animated textures that are new or changed,
    /// and they are checked against its output; without a python3 they are skipped, and the
    /// attachment says so. A texture that left the library is skipped. Skipped when neither
    /// library root is present (CI).
    func testEveryLibrarySpriteTextureParses() throws {
        let textures = try JSONDecoder().decode([LibraryTexture].self, from: Fixtures.data("Library/texs-frames.json"))
        XCTAssertFalse(textures.isEmpty)
        try XCTSkipUnless(Self.roots.values.contains { FileManager.default.fileExists(atPath: $0.path) },
                          "wallpaper library not present")
        var checked = 0
        var removed: [String] = [], changed: [String] = []
        for texture in textures {
            guard let data = try bytes(of: texture) else {
                removed.append(texture.key)
                continue
            }
            guard Self.digest(data) == texture.sha256 else {
                changed.append(texture.key)
                continue
            }
            try check(data, texture)
            checked += 1
        }

        var notes: [String] = []
        if ReferenceScript.python != nil {
            let output = FileManager.default.temporaryDirectory.appending(path: "owe-texs-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: output) } // scratch cleanup
            try ReferenceScript.run("texs-frames.py", arguments: ["--out", output.path],
                                    environment: ["OWE_LIBRARY": Self.roots["storage"]?.path ?? "",
                                                  "OWE_WORKSHOP": Self.roots["workshop"]?.path ?? ""])
            let current = try JSONDecoder().decode([LibraryTexture].self, from: Data(contentsOf: output))
            let known = Dictionary(textures.map { ($0.key, $0.sha256) }, uniquingKeysWith: { first, _ in first })
            let currentKeys = Set(current.map(\.key))
            let beyond = current.filter { known[$0.key] != $0.sha256 }
            for texture in beyond {
                let data = try XCTUnwrap(bytes(of: texture), "\(texture.key): listed by the script, not readable here")
                try check(data, texture)
                checked += 1
            }
            for texture in textures where !removed.contains(texture.key) && !changed.contains(texture.key)
            && !currentKeys.contains(texture.key) {
                XCTFail("\(texture.key): unchanged since the fixture, but Scripts/texs-frames.py no longer finds a TEXS block")
            }
            if !beyond.isEmpty {
                notes.append("\(beyond.count) animated textures new or changed since texs-frames.json, checked against "
                             + "Scripts/texs-frames.py run now: \(beyond.map(\.key).joined(separator: ", "))")
            }
        } else {
            if !changed.isEmpty {
                notes.append("\(changed.count) textures changed since texs-frames.json NOT checked (no python3 to run "
                             + "Scripts/texs-frames.py): \(changed.joined(separator: ", "))")
            }
            notes.append("animated textures new since texs-frames.json not looked for: no python3 to run Scripts/texs-frames.py")
        }
        if !removed.isEmpty {
            notes.append("\(removed.count) textures of the fixture no longer in the library, skipped: \(removed.joined(separator: ", "))")
        }
        if !notes.isEmpty { notes.append("Refresh the fixture: Scripts/texs-frames.py") }
        LibraryReport.attach("Animated textures: beyond texs-frames.json", notes)
        try XCTSkipIf(checked == 0, "no library texture found")
    }

    private static func digest(_ data: Data) -> String {
        Digest.hex(SHA256.hash(data: data))
    }
}
