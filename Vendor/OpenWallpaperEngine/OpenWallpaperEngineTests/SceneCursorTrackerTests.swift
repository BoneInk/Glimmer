import XCTest
@testable import OpenWallpaperEngine

final class SceneCursorTrackerTests: XCTestCase {
    func testKeepsTheLastPositionWhileTheCursorIsOnAnotherDisplay() {
        var tracker = SceneCursorTracker()
        let size = SIMD2<Float>(1920, 1080)
        XCTAssertEqual(tracker.update(nil, sceneSize: size).position, size / 2)
        let seen = tracker.update(SIMD2(100, 200), sceneSize: size)
        XCTAssertEqual(seen.position, SIMD2(100, 200))
        XCTAssertTrue(seen.onDisplay)
        let away = tracker.update(nil, sceneSize: size)
        XCTAssertEqual(away.position, SIMD2(100, 200))
        XCTAssertFalse(away.onDisplay)
    }
}
