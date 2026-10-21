import XCTest
@testable import OWEInspectorKit

/// The slider stays continuous (a stepped `Slider` draws a line of tick marks under the track),
/// so the step is applied by snapping the bound value.
final class NumericSliderInputTests: XCTestCase {
    private typealias Input = NumericSliderInput<Double>

    func testSnapsToNearestStepFromLowerBound() {
        XCTAssertEqual(Input.snapped(1.04, in: 0...2, step: 0.1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Input.snapped(1.06, in: 0...2, step: 0.1), 1.1, accuracy: 1e-9)
        XCTAssertEqual(Input.snapped(10.6, in: 10...120, step: 1), 11)
        XCTAssertEqual(Input.snapped(0.3, in: 0.05...5, step: 0.05), 0.3, accuracy: 1e-9)
    }

    func testClampsToRange() {
        XCTAssertEqual(Input.snapped(-1, in: 0...2, step: 0.1), 0)
        XCTAssertEqual(Input.snapped(5, in: 0...2, step: 0.3), 2)
    }

    func testWithoutStepPassesThrough() {
        XCTAssertEqual(Input.snapped(0.123, in: 0...1, step: nil), 0.123)
    }

    /// A focused field follows a slider drag at once instead of waiting for focus to leave it,
    /// but what the user is typing isn't rewritten while it still says the value.
    func testFocusedFieldMirrorsOutsideChangesLive() {
        XCTAssertTrue(Input.shouldMirror(text: "0.50", displayed: 0.5, isEditing: false, fractionDigits: 2))
        XCTAssertTrue(Input.shouldMirror(text: "0.50", displayed: 0.73, isEditing: true, fractionDigits: 2))
        XCTAssertFalse(Input.shouldMirror(text: "0.5", displayed: 0.5, isEditing: true, fractionDigits: 2))
        XCTAssertFalse(Input.shouldMirror(text: "1.", displayed: 1, isEditing: true, fractionDigits: 2))
        XCTAssertTrue(Input.shouldMirror(text: "abc", displayed: 1, isEditing: true, fractionDigits: 2))
    }
}
