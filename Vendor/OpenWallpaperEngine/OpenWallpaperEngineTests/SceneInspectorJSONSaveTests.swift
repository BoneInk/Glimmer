import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's JSON editors refuse text that isn't a JSON object, with a reason, instead
/// of ignoring the Save.
final class SceneInspectorJSONSaveTests: XCTestCase {
    func testAnObjectIsAccepted() throws {
        let object = try SceneInspectorModel.jsonObject(#"{"alpha": 0.5, "name": "Sky"}"#)
        XCTAssertEqual(object["name"] as? String, "Sky")
    }

    func testUnparseableTextThrowsWithTheParsersReason() {
        XCTAssertThrowsError(try SceneInspectorModel.jsonObject(#"{"alpha": }"#)) { error in
            guard case SceneInspectorModel.InvalidJSON.unparseable(let reason) = error else {
                return XCTFail("expected unparseable, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertNotNil((error as? LocalizedError)?.errorDescription)
        }
    }

    func testJSONThatIsNotAnObjectThrows() {
        for text in ["[1, 2]", #""text""#, "3"] {
            XCTAssertThrowsError(try SceneInspectorModel.jsonObject(text), text) { error in
                guard case SceneInspectorModel.InvalidJSON.notAnObject = error else {
                    return XCTFail("\(text): expected notAnObject, got \(error)")
                }
            }
        }
    }

    func testAttemptReturnsTheValueOrNil() {
        struct Failure: Error {}
        XCTAssertEqual(OWELog.attempt(.ui, "test") { 7 }, 7)
        XCTAssertNil(OWELog.attempt(.ui, "test") { () throws -> Int in throw Failure() })
    }

    func testOnlyANoSuchFileErrorCountsAsMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/file.pkg")
        XCTAssertThrowsError(try Data(contentsOf: missing)) { XCTAssertTrue(OWELog.isMissingFile($0)) }
        XCTAssertThrowsError(try PKGParser(url: missing)) { XCTAssertTrue(OWELog.isMissingFile($0)) }
        XCTAssertThrowsError(try PKGParser(data: Data("nope".utf8))) { XCTAssertFalse(OWELog.isMissingFile($0)) }
    }
}
