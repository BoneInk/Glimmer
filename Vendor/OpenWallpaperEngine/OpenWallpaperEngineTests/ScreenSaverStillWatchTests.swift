import XCTest
@testable import OpenWallpaperEngine

/// The savers' still: which file a view shows, that a still replaced under the same name counts as
/// new, and that a change in the folder reaches the views (System Settings' preview included)
/// without the view being made again.
final class ScreenSaverStillWatchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "owe-stills-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder) // scratch cleanup
    }

    private func list(_ stills: ScreenSaverStills) throws {
        try JSONEncoder().encode(stills).write(to: folder.appending(path: ScreenSaverStills.fileName), options: .atomic)
    }

    /// Writes `bytes` as `name` the way the app does: a new file renamed over the old one.
    private func replace(_ name: String, with bytes: [UInt8]) throws {
        let staging = folder.appending(path: ".\(UUID().uuidString)")
        try Data(bytes).write(to: staging)
        XCTAssertEqual(rename(staging.path, folder.appending(path: name).path), 0)
    }

    func testChoosesThePickThenTheDisplaysOwnStill() throws {
        try replace("still-A.heic", with: [1])
        try replace("still-B.heic", with: [2])
        try list(ScreenSaverStills(stills: ["A": "still-A.heic", "B": "still-B.heic"]))
        XCTAssertEqual(ScreenSaverStillChoice.current(in: folder, display: "B")?.url.lastPathComponent, "still-B.heic")
        XCTAssertEqual(ScreenSaverStillChoice.current(in: folder, display: nil)?.url.lastPathComponent, "still-A.heic",
                       "a view without a display yet shows a display's still, not black")
        try replace(ScreenSaverStillPublisher.pickFileName, with: [3])
        try list(ScreenSaverStills(stills: ["A": "still-A.heic", "B": "still-B.heic"], pick: ScreenSaverStillPublisher.pickFileName))
        XCTAssertEqual(ScreenSaverStillChoice.current(in: folder, display: "B")?.url.lastPathComponent, ScreenSaverStillPublisher.pickFileName)
    }

    func testAMissingStillKeepsWhatIsShown() throws {
        XCTAssertNil(ScreenSaverStillChoice.current(in: folder, display: "A"), "no stills.json yet")
        try list(ScreenSaverStills(stills: ["A": "still-A.heic"]))
        XCTAssertNil(ScreenSaverStillChoice.current(in: folder, display: "A"), "listed but not there")
    }

    /// The app replaces a still by renaming a new link over it: same name, another still.
    func testAStillReplacedUnderItsNameIsNew() throws {
        try replace("still-A.heic", with: [1])
        try list(ScreenSaverStills(stills: ["A": "still-A.heic"]))
        let first = try XCTUnwrap(ScreenSaverStillChoice.current(in: folder, display: "A"))
        XCTAssertEqual(ScreenSaverStillChoice.current(in: folder, display: "A"), first, "unchanged: nothing to decode again")
        try replace("still-A.heic", with: [1])
        let second = try XCTUnwrap(ScreenSaverStillChoice.current(in: folder, display: "A"))
        XCTAssertEqual(second.url, first.url)
        XCTAssertNotEqual(second.key, first.key)
    }

    /// A change to the folder (a still, then its listing) reaches every view once, shortly after;
    /// a view that went away hears nothing.
    @MainActor
    func testTheFolderWatchTellsViewsOfANewStill() throws {
        let watch = ScreenSaverFolderWatch(folder: folder, settle: 0.1)
        final class Owner {}
        let owner = Owner(), gone = Owner()
        let told = expectation(description: "told")
        told.assertForOverFulfill = false
        var count = 0
        watch.add(owner) {
            count += 1
            told.fulfill()
        }
        watch.add(gone) { XCTFail("removed") }
        watch.remove(gone)
        XCTAssertTrue(watch.isWatching)
        try replace("still-A.heic", with: [1])
        try list(ScreenSaverStills(stills: ["A": "still-A.heic"]))
        wait(for: [told], timeout: 3)
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(count, 1, "changes close together are told once")
        watch.remove(owner)
        XCTAssertFalse(watch.isWatching)
    }

    /// The folder doesn't exist until the app first writes it: watched once it does.
    @MainActor
    func testWatchesTheFolderOnceItExists() throws {
        let later = folder.appending(path: "ScreenSaver", directoryHint: .isDirectory)
        let watch = ScreenSaverFolderWatch(folder: later, settle: 0.1)
        final class Owner {}
        let owner = Owner()
        let told = expectation(description: "told")
        watch.add(owner) { told.fulfill() }
        XCTAssertFalse(watch.isWatching)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: true)
        watch.watch()
        XCTAssertTrue(watch.isWatching)
        try Data([1]).write(to: later.appending(path: ScreenSaverStills.fileName), options: .atomic)
        wait(for: [told], timeout: 3)
        watch.remove(owner)
    }
}
