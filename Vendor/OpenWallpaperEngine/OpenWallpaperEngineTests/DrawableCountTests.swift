import XCTest
@testable import OpenWallpaperEngine

final class DrawableCountTests: XCTestCase {
    func testTwoDrawablesUpToSixtyFramesPerSecond() {
        for rate in [1, 15, 24, 30, 60] {
            XCTAssertEqual(SceneWallpaperInstance.maximumDrawableCount(forRate: rate), 2, "\(rate) fps")
        }
    }

    func testThreeDrawablesAboveSixty() {
        for rate in [61, 90, 120, 144] {
            XCTAssertEqual(SceneWallpaperInstance.maximumDrawableCount(forRate: rate), 3, "\(rate) fps")
        }
    }
}
