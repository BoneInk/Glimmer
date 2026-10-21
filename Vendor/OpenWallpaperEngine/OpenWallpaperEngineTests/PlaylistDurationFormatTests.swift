import XCTest
@testable import OpenWallpaperEngine

/// The playlist duration slider's label and steps.
final class PlaylistDurationFormatTests: XCTestCase {
    func testLabels() {
        let english = Locale(identifier: "en_US")
        let expected: [(Double, String)] = [
            (5, "5s"), (45, "45s"), (60, "1m"), (75, "1m 15s"), (90, "1m 30s"),
            (135, "2m 15s"), (3599, "59m 59s"), (3600, "1h"),
        ]
        for (seconds, label) in expected {
            XCTAssertEqual(PlaylistDurationFormat.label(seconds, locale: english), label, "\(seconds)")
        }
    }

    /// The units follow the language: Japanese writes them as 分 and 秒.
    func testLabelsUseTheLocalesUnits() {
        XCTAssertEqual(PlaylistDurationFormat.label(75, locale: Locale(identifier: "ja_JP")), "1分15秒")
    }

    func testSnapsToFiveSecondsBelowAMinuteAndFifteenFromIt() {
        XCTAssertEqual(PlaylistDurationFormat.snapped(5), 5)
        XCTAssertEqual(PlaylistDurationFormat.snapped(47), 45)
        XCTAssertEqual(PlaylistDurationFormat.snapped(58), 60)
        XCTAssertEqual(PlaylistDurationFormat.snapped(68), 75)
        XCTAssertEqual(PlaylistDurationFormat.snapped(135), 135)
        XCTAssertEqual(PlaylistDurationFormat.snapped(3599), 3600)
        XCTAssertEqual(PlaylistDurationFormat.snapped(2), 5)
    }
}
