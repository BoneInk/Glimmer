import XCTest
@testable import OpenWallpaperEngine

/// The sizes the Render Resolution picker shows: Your Display's backing pixels and 4K at each
/// display's shape (`RenderResolutionSizes`).
final class RenderResolutionSizesTests: XCTestCase {
    private func screen(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> RenderResolutionSizes.Screen {
        .init(points: CGSize(width: w, height: h), pixels: CGSize(width: w * scale, height: h * scale))
    }

    func testOneDisplay() {
        let sizes = RenderResolutionSizes(screens: [screen(1920, 1080, scale: 2)])
        XCTAssertEqual(sizes.yourDisplayList, "3840×2160")
        XCTAssertEqual(sizes.uhd4KList, "3840×2160")
    }

    func testTwoDistinctDisplaysListLargestFirst() {
        let sizes = RenderResolutionSizes(screens: [screen(1920, 1080, scale: 1), screen(2560, 1440, scale: 2)])
        XCTAssertEqual(sizes.yourDisplayList, "5120×2880, 1920×1080")
        XCTAssertEqual(sizes.uhd4KList, "3840×2160", "both 16:9: one 4K size")
        XCTAssertEqual(sizes.mainPixels, "1920×1080", "the first screen is the main one")
    }

    func testDuplicateSizesCollapse() {
        let sizes = RenderResolutionSizes(screens: [screen(1920, 1080, scale: 2), screen(1920, 1080, scale: 2)])
        XCTAssertEqual(sizes.yourDisplayList, "3840×2160")
    }

    func testYourDisplayReadsPixelsNotPoints() {
        let sizes = RenderResolutionSizes(screens: [.init(points: CGSize(width: 1710, height: 1112),
                                                          pixels: CGSize(width: 3420, height: 2224))])
        XCTAssertTrue(sizes.label(.yourDisplay).contains("3420×2224"))
        XCTAssertFalse(sizes.label(.yourDisplay).contains("1710"))
        XCTAssertTrue(sizes.summary(.yourDisplay).contains("3420×2224"))
        XCTAssertEqual(sizes.mainUHD4K, "3840×2497", "4K at the display's shape")
    }

    func testCurrentScreensUseFramePoints() throws {
        let main = try XCTUnwrap(NSScreen.screens.first)
        let s = RenderResolutionSizes.screen(main)
        XCTAssertEqual(s.points, main.frame.size)
        XCTAssertGreaterThanOrEqual(s.pixels.width, s.points.width)
    }
}
