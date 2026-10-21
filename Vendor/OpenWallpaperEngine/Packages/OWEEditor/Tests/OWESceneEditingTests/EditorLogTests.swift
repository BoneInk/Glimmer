import Foundation
import XCTest
@testable import OWESceneEditing

/// `EditorLog.attempt` keeps a `try?`'s fallback while logging why; a missing file can stay quiet.
final class EditorLogTests: XCTestCase {
    func testAttemptReturnsTheValueOrNil() {
        struct Failure: Error {}
        XCTAssertEqual(EditorLog.attempt("test") { 7 }, 7)
        XCTAssertNil(EditorLog.attempt("test") { () throws -> Int in throw Failure() })
    }

    func testOnlyANoSuchFileErrorCountsAsMissing() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/state.json")
        XCTAssertThrowsError(try Data(contentsOf: missing)) { XCTAssertTrue(EditorLog.isMissingFile($0)) }
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data("{".utf8))) { XCTAssertFalse(EditorLog.isMissingFile($0)) }
    }

    func testAModelConfigurationThatDoesNotDecodeIsNone() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EditorLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "models"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("not json".utf8).write(to: folder.appending(path: "models/thing.json"))
        let store = EditorAssetStore(directory: folder)
        XCTAssertNil(store.modelConfig(for: "models/thing.mdl"))
    }
}
