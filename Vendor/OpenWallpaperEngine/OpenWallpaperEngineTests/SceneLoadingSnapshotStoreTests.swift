import XCTest
import CoreGraphics
import ImageIO
@testable import OpenWallpaperEngine

/// The pictures shown while a scene loads: chosen by wallpaper, content and display size,
/// replaced when the wallpaper's files change, capped as an LRU, and kept in the isolated Caches.
final class SceneLoadingSnapshotStoreTests: XCTestCase {
    private var root: URL!
    private var caches: URL!
    private var wallpaper: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SceneLoadingSnapshotStoreTests-\(UUID().uuidString)")
        caches = root.appending(path: "Caches", directoryHint: .isDirectory)
        wallpaper = root.appending(path: "Library/123456", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: wallpaper, withIntermediateDirectories: true)
        try Data(#"{"type":"scene","file":"scene.json"}"#.utf8).write(to: wallpaper.appending(path: "project.json"))
        try Data("{}".utf8).write(to: wallpaper.appending(path: "scene.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixelSize(of url: URL?) throws -> SIMD2<Int> {
        let entry = try XCTUnwrap(url.flatMap(SceneLoadingSnapshotStore.entry))
        return entry.pixelSize
    }

    func testChoosesTheExactSizeElseTheNearest() throws {
        let store = SceneLoadingSnapshotStore(cachesDirectory: caches)
        let key = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper))
        for (width, height) in [(160, 90), (320, 180), (200, 200)] {
            try store.write(try image(width: width, height: height), forWallpaperAt: wallpaper, contentKey: key)
        }
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(320, 180))), SIMD2(320, 180))
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(300, 170))), SIMD2(320, 180))
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(180, 100))), SIMD2(160, 90))
        // Same aspect beats a closer pixel count of another aspect.
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(1920, 1080))), SIMD2(320, 180))
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(1000, 1000))), SIMD2(200, 200))
        // Another wallpaper, or another content key, has none.
        let other = root.appending(path: "Library/654321", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertNil(store.bestSnapshot(forWallpaperAt: other, pixelSize: SIMD2(320, 180)))
        XCTAssertNil(store.bestSnapshot(forWallpaperAt: wallpaper, contentKey: "0000", pixelSize: SIMD2(320, 180)))
    }

    func testNearestPrefersTheSameAspect() {
        let sizes = [SIMD2(2560, 1440), SIMD2(1920, 1200), SIMD2(5120, 2880)]
        XCTAssertEqual(SceneLoadingSnapshotStore.nearest(sizes, to: SIMD2(3840, 2160)), SIMD2(5120, 2880))
        XCTAssertEqual(SceneLoadingSnapshotStore.nearest(sizes, to: SIMD2(5120, 2880)), SIMD2(5120, 2880))
        XCTAssertEqual(SceneLoadingSnapshotStore.nearest(sizes, to: SIMD2(2880, 1800)), SIMD2(1920, 1200))
        XCTAssertNil(SceneLoadingSnapshotStore.nearest([], to: SIMD2(1, 1)))
    }

    func testChangedContentInvalidatesTheSnapshot() throws {
        let store = SceneLoadingSnapshotStore(cachesDirectory: caches)
        let before = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper))
        let old = try store.write(try image(width: 64, height: 36), forWallpaperAt: wallpaper, contentKey: before)
        XCTAssertNotNil(store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(64, 36)))

        // A Workshop update rewrites the scene.
        let scene = wallpaper.appending(path: "scene.json")
        try Data(#"{"objects":[]}"#.utf8).write(to: scene)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: scene.path)
        let after = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper))
        XCTAssertNotEqual(before, after)
        XCTAssertNil(store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(64, 36)), "the old picture is stale")

        // The next snapshot replaces every one of the old content.
        try store.write(try image(width: 32, height: 18), forWallpaperAt: wallpaper, contentKey: after)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(store.entries(for: wallpaper).map(\.contentKey), [after])
        XCTAssertEqual(try pixelSize(of: store.bestSnapshot(forWallpaperAt: wallpaper, pixelSize: SIMD2(64, 36))), SIMD2(32, 18))
    }

    func testSnapshotIsAFullResolutionImage() throws {
        let store = SceneLoadingSnapshotStore(cachesDirectory: caches)
        let key = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper))
        let url = try store.write(try image(width: 640, height: 360), forWallpaperAt: wallpaper, contentKey: key)
        XCTAssertTrue(["heic", "jpg"].contains(url.pathExtension))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 640)
        XCTAssertEqual(decoded.height, 360)
    }

    func testLeastRecentlyUsedGoFirstOverTheCap() throws {
        let unbounded = SceneLoadingSnapshotStore(cachesDirectory: caches)
        var written: [URL] = []
        for index in 0..<3 {
            let folder = root.appending(path: "Library/\(index)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("\(index)".utf8).write(to: folder.appending(path: "project.json"))
            let key = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: folder))
            let url = try unbounded.write(try image(width: 64, height: 36), forWallpaperAt: folder, contentKey: key)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 10))],
                                                  ofItemAtPath: url.path)
            written.append(url)
        }
        let sizes = try written.map { try XCTUnwrap($0.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        // Room for the two newest only.
        let capped = SceneLoadingSnapshotStore(cachesDirectory: caches, capacityBytes: sizes[1] + sizes[2])
        capped.trim()
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: written[0].deletingLastPathComponent().path), "empty folder removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: written[2].path))
    }

    func testDeletingAWallpaperRemovesItsSnapshots() throws {
        let store = SceneLoadingSnapshotStore(cachesDirectory: caches)
        let key = try XCTUnwrap(SceneLoadingSnapshotStore.contentKey(for: wallpaper))
        try store.write(try image(width: 64, height: 36), forWallpaperAt: wallpaper, contentKey: key)
        XCTAssertFalse(store.entries(for: wallpaper).isEmpty)
        try FileManager.default.removeItem(at: wallpaper)
        store.removeSnapshots(forWallpaperAt: wallpaper)
        XCTAssertTrue(store.entries(for: wallpaper).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder(for: wallpaper).path))
    }

    func testStoreLivesInTheIsolatedCaches() {
        let location = AppStorageLocation.current
        XCTAssertTrue(location.isIsolated)
        let directory = SceneLoadingSnapshotStore.current.directory.standardizedFileURL.path
        XCTAssertTrue(directory.hasPrefix(location.cachesDirectory.standardizedFileURL.path + "/"))
        XCTAssertTrue(directory.contains("Open Wallpaper Engine (isolated tests)"), directory)
        let real = AppStorageLocation(isolationTag: nil)
        XCTAssertFalse(directory.hasPrefix(SceneLoadingSnapshotStore(cachesDirectory: real.cachesDirectory).directory.path))
    }

    func testSessionCapturesEachSizeOnceUntilThePropertiesChange() {
        let session = SceneLoadingSnapshotSession(store: SceneLoadingSnapshotStore(cachesDirectory: caches))
        let capture = SceneLoadingSnapshotCapture(wallpaperDirectory: wallpaper, session: session, now: 100)
        let size = SIMD2(3840, 2160)
        XCTAssertFalse(capture.claim(pixelSize: size, contentSince: 101, now: 102), "not shown long enough")
        XCTAssertTrue(capture.claim(pixelSize: size, contentSince: 101, now: 110))
        XCTAssertFalse(capture.claim(pixelSize: size, contentSince: 101, now: 120), "once per session")
        XCTAssertTrue(capture.claim(pixelSize: SIMD2(1920, 1080), contentSince: 101, now: 120), "another display size")
        // Another instance of the wallpaper in the same session doesn't capture again.
        let again = SceneLoadingSnapshotCapture(wallpaperDirectory: wallpaper, session: session, now: 100)
        XCTAssertFalse(again.claim(pixelSize: size, contentSince: 101, now: 130))
        capture.rearm(now: 200)
        XCTAssertFalse(capture.claim(pixelSize: size, contentSince: 101, now: 201), "the new look shows first")
        XCTAssertTrue(capture.claim(pixelSize: size, contentSince: 101, now: 210))
    }
}
