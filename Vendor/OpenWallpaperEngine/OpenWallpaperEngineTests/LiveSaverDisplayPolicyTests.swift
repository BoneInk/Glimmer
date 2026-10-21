import XCTest
@testable import OpenWallpaperEngine

/// The savers' choice between live frames and the video, and how fast a view ticks.
final class LiveSaverDisplayPolicyTests: XCTestCase {
    func testGoesLiveAfterSteadyFramesAndFallsBackWhenTheyStop() {
        var fallback = LiveFrameFallback()
        fallback.frameArrived(at: 0)
        fallback.frameArrived(at: 0.03)
        XCTAssertEqual(fallback.update(at: 0.04), .fallback)
        fallback.frameArrived(at: 0.06)
        XCTAssertEqual(fallback.update(at: 0.07), .live)
        XCTAssertEqual(fallback.update(at: 0.06 + LiveFrameFallback.staleAfter), .live)
        XCTAssertEqual(fallback.update(at: 0.07 + LiveFrameFallback.staleAfter), .fallback)
    }

    func testAFrameAfterAGapStartsTheCountAgain() {
        var fallback = LiveFrameFallback()
        fallback.frameArrived(at: 0)
        fallback.frameArrived(at: 0.1)
        fallback.frameArrived(at: 1)
        XCTAssertEqual(fallback.update(at: 1), .fallback)
        fallback.frameArrived(at: 1.1)
        fallback.frameArrived(at: 1.2)
        XCTAssertEqual(fallback.update(at: 1.2), .live)
    }

    func testResumesLiveAtOnce() {
        var fallback = LiveFrameFallback()
        fallback.resume(at: 5)
        XCTAssertEqual(fallback.update(at: 5), .live, "a new view of a process already showing live frames")
        XCTAssertEqual(fallback.update(at: 5.1 + LiveFrameFallback.staleAfter), .fallback, "still falls back when they stop")
    }

    func testAParkedViewDrawsOneFrameASecond() {
        XCTAssertTrue(SaverParkPolicy.mayDraw(parked: false, at: 1, lastDrawn: 0.99), "every frame at full rate")
        XCTAssertTrue(SaverParkPolicy.mayDraw(parked: true, at: 10, lastDrawn: nil))
        XCTAssertFalse(SaverParkPolicy.mayDraw(parked: true, at: 10, lastDrawn: 9.5))
        XCTAssertTrue(SaverParkPolicy.mayDraw(parked: true, at: 10.5, lastDrawn: 9.5))
    }

    func testResetFallsBackAtOnce() {
        var fallback = LiveFrameFallback()
        for time in [0.0, 0.01, 0.02] { fallback.frameArrived(at: time) }
        XCTAssertEqual(fallback.update(at: 0.02), .live)
        fallback.reset()
        XCTAssertEqual(fallback.mode, .fallback)
    }

    /// System Settings' preview draws at full rate while starting and while its window is
    /// visible, and parks once it isn't (the Settings window hidden or closed).
    func testThePreviewParksWhenItsWindowIsntVisible() {
        XCTAssertFalse(SaverParkPolicy.previewParked(startedAt: 10, lastVisible: nil, at: 10 + SaverParkPolicy.startGrace),
                       "full rate while starting")
        XCTAssertTrue(SaverParkPolicy.previewParked(startedAt: 10, lastVisible: nil, at: 10.1 + SaverParkPolicy.startGrace))
        XCTAssertFalse(SaverParkPolicy.previewParked(startedAt: 0, lastVisible: 20, at: 21))
        XCTAssertTrue(SaverParkPolicy.previewParked(startedAt: 0, lastVisible: 20, at: 20.1 + SaverParkPolicy.visibleGrace))
    }

    /// A frame's crop (y down from the top, as the app draws) is the layer's `contentsRect`
    /// (unit coordinates, y up): a stretch's left half, a stacked display's top half.
    func testACropIsTheLayersContentsRect() {
        XCTAssertEqual(ScreenSaverManifest.contentsRect(for: nil), CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(ScreenSaverManifest.contentsRect(for: .init(x: 0, y: 0, width: 0.5, height: 1)),
                       CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(ScreenSaverManifest.contentsRect(for: .init(x: 0, y: 0, width: 1, height: 0.5)),
                       CGRect(x: 0, y: 0.5, width: 1, height: 0.5))
    }

    func testSmallViewsArePreviewsWhateverTheirFlag() {
        XCTAssertTrue(SaverParkPolicy.isPreview(flag: true, size: CGSize(width: 1920, height: 1080)))
        XCTAssertTrue(SaverParkPolicy.isPreview(flag: false, size: CGSize(width: 296, height: 184)))
        XCTAssertFalse(SaverParkPolicy.isPreview(flag: false, size: CGSize(width: 1512, height: 982)))
    }
}
