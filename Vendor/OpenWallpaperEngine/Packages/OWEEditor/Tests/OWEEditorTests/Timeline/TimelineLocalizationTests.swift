import XCTest
@testable import OWEEditor
@testable import OWESceneEditing

/// The timeline's texts resolve from its table (`Resources/Timeline.xcstrings`, checked by
/// `CatalogCoverageTests`), and its scale maps time across the width.
final class TimelineLocalizationTests: XCTestCase {
    func testEnglishTextResolvesFromItsTable() {
        XCTAssertEqual(T("Timeline"), "Timeline")
        XCTAssertEqual(T("Frame \(96)"), "Frame 96")
        XCTAssertEqual(TimelineEase.easeInOut.title, "Ease In and Out")
        XCTAssertEqual(TimelineNames.field("angles"), "Rotation")
        XCTAssertEqual(TimelineNames.time(83.25), "1:23.25")
    }

    func testTheScaleMapsTimeAcrossTheWidth() {
        let scale = TimelineScale(duration: 4, width: 424)
        XCTAssertEqual(scale.x(0), TimelineScale.inset)
        XCTAssertEqual(scale.x(4), 424 - TimelineScale.inset)
        XCTAssertEqual(scale.seconds(scale.x(1.5)), 1.5, accuracy: 1e-9)
        XCTAssertEqual(scale.pointsPerFrame(fps: 25), 4, accuracy: 1e-9)
        XCTAssertEqual(scale.tickStep(), 1, "the shortest step at least 64 points apart")
    }
}
