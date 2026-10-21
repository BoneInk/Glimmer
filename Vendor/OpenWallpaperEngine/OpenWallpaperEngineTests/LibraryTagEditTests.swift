import XCTest
@testable import OpenWallpaperEngine

/// Tag edits in the Details inspector trim, dedupe ignoring case and keep the written order.
final class LibraryTagEditTests: XCTestCase {
    func testAddingTrimsAndSkipsDuplicates() {
        XCTAssertEqual(ProjectTagList.adding("  Nature ", to: ["Anime", "Cars"]), ["Anime", "Cars", "Nature"])
        XCTAssertEqual(ProjectTagList.adding("anime", to: ["Anime", "Cars"]), ["Anime", "Cars"])
        XCTAssertEqual(ProjectTagList.adding("   ", to: ["Anime"]), ["Anime"])
    }

    func testRemovingKeepsTheOtherTagsInOrder() {
        XCTAssertEqual(ProjectTagList.removing("Cars", from: ["Zeta", "Cars", "Anime", "cars"]), ["Zeta", "Anime"])
    }
}
