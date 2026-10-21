import XCTest
@testable import OpenWallpaperEngine

/// Editing tags or the content rating of a local wallpaper writes only those keys to project.json.
final class WallpaperProjectFileEditTests: XCTestCase {
    func testTagAndRatingEditsKeepEveryOtherKey() throws {
        let directory = try Fixtures.temporaryCopy(of: "Library/project-edit")
        defer { try? FileManager.default.removeItem(at: directory) } // cleanup of a temporary copy
        let original = try projectObject(in: directory)

        try WallpaperProjectFileEdit.set(["tags": ["Abstract", "Nature"]], inProjectAt: directory)
        try WallpaperProjectFileEdit.set(["contentrating": "Mature"], inProjectAt: directory)

        let edited = try projectObject(in: directory)
        XCTAssertEqual(edited["tags"] as? [String], ["Abstract", "Nature"])
        XCTAssertEqual(edited["contentrating"] as? String, "Mature")
        var expected = original
        expected["tags"] = ["Abstract", "Nature"]
        expected["contentrating"] = "Mature"
        XCTAssertEqual(edited as NSDictionary, expected as NSDictionary)

        let properties = try XCTUnwrap((edited["general"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), ["schemecolor", "speed", "showclock"])
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        XCTAssertEqual(project.tags, ["Abstract", "Nature"])
        XCTAssertEqual(project.contentrating, "Mature")
    }

    func testNilRemovesKey() throws {
        let directory = try Fixtures.temporaryCopy(of: "Library/project-edit")
        defer { try? FileManager.default.removeItem(at: directory) } // cleanup of a temporary copy
        try WallpaperProjectFileEdit.set(["tags": nil], inProjectAt: directory)
        XCTAssertNil(try projectObject(in: directory)["tags"])
    }

    func testMissingProjectThrows() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        XCTAssertThrowsError(try WallpaperProjectFileEdit.set(["tags": ["A"]], inProjectAt: directory))
    }

    private func projectObject(in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appending(path: "project.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
