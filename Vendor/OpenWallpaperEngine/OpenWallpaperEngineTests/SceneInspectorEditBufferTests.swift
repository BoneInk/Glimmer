import XCTest
@testable import OpenWallpaperEngine

/// Scene Edit / Export's edits read back before the debounced save. The slider's own tests moved
/// with it to `Packages/OWEEditor` (`NumericSliderInputTests`).
final class SceneInspectorEditBufferTests: XCTestCase {
    /// An inspector edit reads back at once, before the debounced save lands in the store.
    func testInspectorEditReadsBackBeforeTheSave() {
        var buffer = SceneInspectorEditBuffer()
        let stored: [String: String] = ["a_musicAmount": "0"]
        XCTAssertEqual(buffer.values(stored: stored)["a_musicAmount"], "0")
        buffer.pending = ["a_musicAmount": "0.4", "b": "1"]
        XCTAssertEqual(buffer.values(stored: stored)["a_musicAmount"], "0.4")
        var next: [String: String] = buffer.values(stored: stored)
        next["c"] = "2"
        XCTAssertEqual(next["b"], "1", "a second edit inside the debounce keeps the first")
    }
}
