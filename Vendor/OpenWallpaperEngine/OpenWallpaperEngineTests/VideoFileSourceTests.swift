import AVFoundation
import XCTest
@testable import OpenWallpaperEngine

/// WE's "Video loading" (`videoreadmode`: `fromdisk`, the default, or `frommemory`): in memory,
/// the file is read once and the player items read it through `MemoryVideoLoader`.
final class VideoFileSourceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "VideoFileSourceTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testTheSettingIsWEsAndFromDiskByDefault() throws {
        XCTAssertEqual(GlobalSettings().videoReadMode, .fromDisk)
        XCTAssertEqual(GSVideoReadMode.fromDisk.rawValue, "fromdisk")
        XCTAssertEqual(GSVideoReadMode.inMemory.rawValue, "frommemory")
        let stored = Data(#"{"videoReadMode": "frommemory"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(GlobalSettings.self, from: stored).videoReadMode, .inMemory)
        XCTAssertEqual(SceneRenderSettings(GlobalSettings()).videoReadMode, .fromDisk)
    }

    func testFromDiskOpensTheFileAndReadsNothingNow() throws {
        let url = try VideoClipFixture.make(frames: 10, in: directory)
        let source = VideoFileSource(url: url, mode: .fromDisk)
        XCTAssertFalse(source.isInMemory)
        XCTAssertEqual((source.makeItem().asset as? AVURLAsset)?.url, url)
    }

    func testAMemoryItemPlaysTheSameVideo() async throws {
        let url = try VideoClipFixture.make(frames: 30, in: directory)
        let source = VideoFileSource(url: url, mode: .inMemory)
        XCTAssertTrue(source.isInMemory)
        let item = source.makeItem()
        let asset = try XCTUnwrap(item.asset as? AVURLAsset)
        XCTAssertEqual(asset.url.scheme, MemoryVideoLoader.scheme)

        let disk = AVURLAsset(url: url)
        let memoryDuration = try await asset.load(.duration)
        let diskDuration = try await disk.load(.duration)
        XCTAssertEqual(memoryDuration, diskDuration)
        let memoryTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(memoryTracks.count, 1)
        let size = try await memoryTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 64, height: 64))

        // The last frame decodes from memory as from the file.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: 29, timescale: 30)).image
        XCTAssertEqual(image.width, 64)
        withExtendedLifetime(source) {}
    }

    func testTheLoaderServesTheFilesBytes() throws {
        let bytes = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let loader = MemoryVideoLoader(data: bytes, contentType: "public.mpeg-4")
        XCTAssertEqual(loader.bytes(100..<300), bytes.subdata(in: 100..<300))
        XCTAssertEqual(loader.bytes(0..<0), Data())
        XCTAssertEqual(MemoryVideoLoader.range(offset: 4000, length: 2000, toEnd: false, fileLength: 5000), 4000..<5000)
        XCTAssertEqual(MemoryVideoLoader.range(offset: 10, length: 2, toEnd: true, fileLength: 5000), 10..<5000)
        XCTAssertNil(MemoryVideoLoader.range(offset: 5001, length: 2, toEnd: false, fileLength: 5000))
        XCTAssertNil(MemoryVideoLoader.range(offset: -1, length: 2, toEnd: false, fileLength: 5000))
        XCTAssertNotEqual(loader.assetURL(named: "a.mp4"), MemoryVideoLoader(data: bytes, contentType: "x").assetURL(named: "a.mp4"))
    }

    func testBytesHandedOutOutliveTheLoader() throws {
        var loader: MemoryVideoLoader? = MemoryVideoLoader(data: Data(repeating: 9, count: 64), contentType: "public.mpeg-4")
        let slice = try XCTUnwrap(loader?.bytes(8..<16))
        loader = nil
        XCTAssertEqual(slice, Data(repeating: 9, count: 8))
    }

    func testTypesAreUTIs() {
        XCTAssertEqual(VideoFileSource.contentType(of: URL(fileURLWithPath: "/a/b.mp4")), "public.mpeg-4")
        XCTAssertEqual(VideoFileSource.contentType(of: URL(fileURLWithPath: "/a/b.mov")), "com.apple.quicktime-movie")
        XCTAssertEqual(VideoFileSource.contentType(of: URL(fileURLWithPath: "/a/b")), "public.mpeg-4")
    }

    func testAFileThatCantBeReadPlaysFromDisk() {
        let missing = directory.appending(path: "missing.mp4")
        let source = VideoFileSource(url: missing, mode: .inMemory)
        XCTAssertFalse(source.isInMemory)
        XCTAssertEqual((source.makeItem().asset as? AVURLAsset)?.url, missing)
    }
}
