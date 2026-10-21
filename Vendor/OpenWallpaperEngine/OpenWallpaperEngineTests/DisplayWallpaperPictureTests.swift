import XCTest
import CoreGraphics
@testable import OpenWallpaperEngine

/// Display Settings' miniature of a display: which picture it shows, in what order, and the
/// display-shaped frame it is drawn in.
final class DisplayWallpaperPictureTests: XCTestCase {
    private let exact = URL(fileURLWithPath: "/snapshots/key-2560x1440.heic")
    private let other = URL(fileURLWithPath: "/snapshots/key-1920x1080.heic")
    private let frame = URL(fileURLWithPath: "/frames/video.jpg")
    private let preview = URL(fileURLWithPath: "/wallpaper/preview.gif")

    private func choose(_ type: String, exact: URL? = nil, other: URL? = nil, frame: URL? = nil,
                        preview: URL? = nil, grabbed: (() -> Void)? = nil) async -> DisplayPictureSource {
        await DisplayPictureSource.choose(type: type, exactSnapshot: exact, otherSnapshot: other,
                                          videoFrame: { grabbed?(); return frame }, preview: preview)
    }

    // MARK: Fallback order

    func testTheSnapshotAtTheDisplaysSizeComesFirst() async {
        let source = await choose("scene", exact: exact, other: other, preview: preview)
        XCTAssertEqual(source, .snapshot(exact))
        XCTAssertEqual(source.placement(.fit), .fill, "A snapshot is the screen as rendered")
    }

    func testAnotherSizesSnapshotIsAspectFilled() async {
        let source = await choose("scene", other: other, preview: preview)
        XCTAssertEqual(source, .otherSnapshot(other))
        XCTAssertEqual(source.placement(.stretch), .fill)
    }

    func testAVideoShowsItsFrameAndGrabsItOnlyWithoutASnapshot() async {
        var grabs = 0
        let video = await choose("Video", frame: frame, preview: preview, grabbed: { grabs += 1 })
        XCTAssertEqual(video, .videoFrame(frame))
        XCTAssertEqual(video.placement(.fit), .fit, "A video frame is placed as the video is")
        _ = await choose("video", other: other, frame: frame, preview: preview, grabbed: { grabs += 1 })
        _ = await choose("scene", frame: frame, preview: preview, grabbed: { grabs += 1 })
        XCTAssertEqual(grabs, 1)
    }

    func testAVideoWithoutAFrameFallsBackToThePreview() async {
        let source = await choose("video", preview: preview)
        XCTAssertEqual(source, .workshopPreview(preview))
    }

    func testAWebWallpaperShowsItsPreview() async {
        let source = await choose("web", frame: frame, preview: preview)
        XCTAssertEqual(source, .webPreview(preview))
    }

    func testTheWorkshopPreviewComesLast() async {
        let scene = await choose("scene", preview: preview)
        let nothing = await choose("scene")
        XCTAssertEqual(scene, .workshopPreview(preview))
        XCTAssertEqual(nothing, .none)
        XCTAssertNil(nothing.url)
    }

    // MARK: Display-shaped frame

    private let box = CGSize(width: 160, height: 72)

    private func assertAspect(_ size: CGSize, _ expected: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(size.width / size.height, expected, accuracy: 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, box.width + 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(size.height, box.height + 0.001, file: file, line: line)
    }

    func testFrameHasTheDisplaysAspect() {
        let wide = DisplayPictureGeometry.frameSize(display: CGSize(width: 1920, height: 1080), fitting: box)
        assertAspect(wide, 16.0 / 9.0)
        XCTAssertEqual(wide.height, 72, accuracy: 0.001)
        XCTAssertEqual(wide.width, 128, accuracy: 0.001)

        let sixteenTen = DisplayPictureGeometry.frameSize(display: CGSize(width: 1728, height: 1080), fitting: box)
        assertAspect(sixteenTen, 16.0 / 10.0)
        XCTAssertEqual(sixteenTen.height, 72, accuracy: 0.001)
        XCTAssertEqual(sixteenTen.width, 115.2, accuracy: 0.001)

        let ultrawide = DisplayPictureGeometry.frameSize(display: CGSize(width: 3440, height: 1440), fitting: box)
        assertAspect(ultrawide, 3440.0 / 1440.0)
        XCTAssertEqual(ultrawide.width, 160, accuracy: 0.001, "21:9 is limited by the box's width")
        XCTAssertEqual(ultrawide.height, 160 * 1440 / 3440, accuracy: 0.001)
    }

    func testFillCropsASquarePreviewToTheDisplay() {
        let frame = DisplayPictureGeometry.frameSize(display: CGSize(width: 3440, height: 1440), fitting: box)
        let rect = DisplayPictureGeometry.imageRect(image: CGSize(width: 512, height: 512), in: frame, placement: .fill)
        XCTAssertEqual(rect.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(rect.height, frame.width, accuracy: 0.001)
        XCTAssertEqual(rect.midX, frame.width / 2, accuracy: 0.001)
        XCTAssertEqual(rect.midY, frame.height / 2, accuracy: 0.001)
    }

    func testFitLetterboxesAndStretchTakesTheFrame() {
        let frame = DisplayPictureGeometry.frameSize(display: CGSize(width: 2560, height: 1600), fitting: box)
        let video = CGSize(width: 1920, height: 1080)
        let fit = DisplayPictureGeometry.imageRect(image: video, in: frame, placement: .fit)
        XCTAssertEqual(fit.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(fit.height, frame.width * 9 / 16, accuracy: 0.001)
        XCTAssertGreaterThan(fit.minY, 0)
        let stretch = DisplayPictureGeometry.imageRect(image: video, in: frame, placement: .stretch)
        XCTAssertEqual(stretch, CGRect(origin: .zero, size: frame))
    }

    func testDecodesAtTheDrawnSizeNotThePicturesOwn() {
        let frame = DisplayPictureGeometry.frameSize(display: CGSize(width: 1920, height: 1080), fitting: box)
        let fourK = CGSize(width: 3840, height: 2160)
        XCTAssertEqual(DisplayPictureGeometry.decodePixelSize(image: fourK, in: frame, placement: .fill, scale: 2), 256)
        let small = CGSize(width: 100, height: 100)
        XCTAssertEqual(DisplayPictureGeometry.decodePixelSize(image: small, in: frame, placement: .fill, scale: 2), 100)
    }
}
