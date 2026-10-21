import XCTest
@testable import WEFormat

/// A wallpaper folder's project.json, found and read in one place.
final class WEProjectFileTests: XCTestCase {
    func testFindsAndReadsTheProject() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "WEProjectFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(WEProjectFile.url(in: folder), folder.appending(path: "project.json"))
        XCTAssertFalse(WEProjectFile.exists(in: folder))
        XCTAssertThrowsError(try WEProjectFile.data(in: folder))

        try Data(#"{"title": "A", "type": "scene"}"#.utf8).write(to: WEProjectFile.url(in: folder))
        XCTAssertTrue(WEProjectFile.exists(in: folder))
        XCTAssertEqual(try WEProjectFile.json(in: folder)?["title"] as? String, "A")

        try Data("[1]".utf8).write(to: WEProjectFile.url(in: folder))
        XCTAssertNil(try WEProjectFile.json(in: folder), "a root that isn't an object")
        try Data("{\"a\": ".utf8).write(to: WEProjectFile.url(in: folder))
        XCTAssertThrowsError(try WEProjectFile.object(in: folder))
    }
}
