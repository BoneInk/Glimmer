import XCTest
@testable import OpenWallpaperEngine

/// The live screen saver's manifest (`live.json`) and frame stamps, which the app writes and the
/// savers read.
final class ScreenSaverLiveManifestTests: XCTestCase {
    private func manifest() -> ScreenSaverLiveManifest {
        ScreenSaverLiveManifest(generation: 7, pid: 42, frameRate: 60, rings: [
            .init(id: 0, width: 3840, height: 2160, surfaces: [1, 2, 3], notifyName: ScreenSaverLiveNames.frameNotification(ring: 0)),
            .init(id: 1, width: 2560, height: 1664, surfaces: [4, 5, 6], notifyName: ScreenSaverLiveNames.frameNotification(ring: 1)),
        ], displays: [
            .init(display: "A", ring: 0, crop: nil),
            .init(display: "B", ring: 1, crop: ScreenSaverManifest.Crop(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])
    }

    func testRoundTripsThroughTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: ScreenSaverLiveManifest.fileName)
        try JSONEncoder().encode(manifest()).write(to: url)
        XCTAssertEqual(ScreenSaverLiveManifest.read(url), manifest())
    }

    func testAnotherRevisionOrNoFileReadsAsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: ScreenSaverLiveManifest.fileName)
        XCTAssertNil(ScreenSaverLiveManifest.read(url), "no file")
        var newer = manifest()
        newer.revision = ScreenSaverLiveManifest.revision + 1
        try JSONEncoder().encode(newer).write(to: url)
        XCTAssertNil(ScreenSaverLiveManifest.read(url), "a newer app's format is skipped")
        try Data("{\"revision\":".utf8).write(to: url)
        XCTAssertNil(ScreenSaverLiveManifest.read(url), "a half-written file")
    }

    func testADisplayGetsItsEntryElseTheOneForAnyDisplay() {
        let listed = manifest()
        XCTAssertEqual(listed.entry(forDisplay: "A", pixels: (100, 100))?.ring.id, 0)
        let stretched = listed.entry(forDisplay: "B", pixels: (100, 100))
        XCTAssertEqual(stretched?.ring.id, 1)
        XCTAssertEqual(stretched?.display.crop?.x, 0.5)
        XCTAssertNil(listed.entry(forDisplay: "C", pixels: (2560, 1664)), "a known display that isn't listed plays its video")

        var any = listed
        any.displays = [.init(display: nil, ring: 1, crop: nil)]
        XCTAssertEqual(any.entry(forDisplay: "C", pixels: (100, 100))?.ring.id, 1)
    }

    func testAnUnknownDisplayTakesTheNearestWholeRing() {
        let listed = manifest()
        XCTAssertEqual(listed.entry(forDisplay: nil, pixels: (3840, 2160))?.ring.id, 0, "the cropped ring isn't a whole picture")
        var both = listed
        both.displays[1].crop = nil
        XCTAssertEqual(both.entry(forDisplay: nil, pixels: (2940, 1912))?.ring.id, 1, "the same shape first")
    }

    func testIsLiveOnlyWithRingsAndDisplays() {
        XCTAssertTrue(manifest().isLive)
        XCTAssertFalse(ScreenSaverLiveManifest().isLive)
        var noDisplays = manifest()
        noDisplays.displays = []
        XCTAssertFalse(noDisplays.isLive)
    }

    // MARK: Stamps

    func testAStampRoundTripsThroughTheNotificationState() {
        let stamp = ScreenSaverLiveStamp(generation: 0xBEEF, frame: 0xDEAD_BEEF, slot: 2)
        XCTAssertEqual(ScreenSaverLiveStamp(state: stamp.state), stamp)
        XCTAssertNil(ScreenSaverLiveStamp(state: 0), "0 is nothing drawn")
        XCTAssertEqual(ScreenSaverLiveStamp.generation(0x1_0005), 5, "generations wrap at 16 bits")
    }

    func testNewerFollowsTheFrameNumberAcrossItsWrap() {
        let old = ScreenSaverLiveStamp(generation: 1, frame: 10, slot: 0)
        XCTAssertTrue(ScreenSaverLiveStamp(generation: 1, frame: 11, slot: 1).isNewer(than: old))
        XCTAssertFalse(ScreenSaverLiveStamp(generation: 1, frame: 9, slot: 1).isNewer(than: old))
        XCTAssertFalse(old.isNewer(than: old))
        let last = ScreenSaverLiveStamp(generation: 1, frame: .max, slot: 0)
        XCTAssertTrue(ScreenSaverLiveStamp(generation: 1, frame: 1, slot: 1).isNewer(than: last), "wrapped")
        XCTAssertTrue(ScreenSaverLiveStamp(generation: 2, frame: 1, slot: 0).isNewer(than: old), "new rings")
        XCTAssertTrue(old.isNewer(than: nil))
    }
}
