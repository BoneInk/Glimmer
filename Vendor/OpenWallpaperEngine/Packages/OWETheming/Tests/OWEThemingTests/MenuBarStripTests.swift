import CoreGraphics
import ImageIO
import XCTest
@testable import OWETheming

final class MenuBarStripTests: XCTestCase {
    func testHeightFromVisibleFrame() {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        XCTAssertEqual(MenuBarStrip.height(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958),
                                           safeAreaTop: 0), 24)
        // A notched display: the safe area is taller than the visible frame's inset.
        XCTAssertEqual(MenuBarStrip.height(frame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 958),
                                           safeAreaTop: 32), 32)
        // A menu bar that hides itself leaves no strip.
        XCTAssertEqual(MenuBarStrip.height(frame: frame, visibleFrame: frame, safeAreaTop: 0), 0)
        // A secondary display's frame is offset; only the difference counts.
        let offset = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        XCTAssertEqual(MenuBarStrip.height(frame: offset, visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415),
                                           safeAreaTop: 0), 25)
    }

    func testImageRectSameAspect() throws {
        // A 2x image of the display: the strip is the top 48 pixels.
        let rect = try XCTUnwrap(MenuBarStrip.imageRect(height: 24, displaySize: CGSize(width: 1512, height: 982),
                                                        imageSize: CGSize(width: 3024, height: 1964)))
        XCTAssertEqual(rect, CGRect(x: 0, y: 1964 - 48, width: 3024, height: 48))
    }

    func testImageRectTallerImageIsCroppedTopAndBottom() throws {
        // A square image on a 16:9 display: Fill Screen shows its middle 1000x562.5.
        let rect = try XCTUnwrap(MenuBarStrip.imageRect(height: 90, displaySize: CGSize(width: 1600, height: 900),
                                                        imageSize: CGSize(width: 1000, height: 1000)))
        let visibleTop = (1000 + 562.5) / 2
        XCTAssertEqual(rect.maxY, visibleTop.rounded(.up))
        XCTAssertEqual(rect.minY, (visibleTop - 56.25).rounded(.down))
        XCTAssertEqual(rect.width, 1000)
    }

    func testImageRectWiderImageKeepsTop() throws {
        // A wide image is cropped left and right; its top is the display's top.
        let rect = try XCTUnwrap(MenuBarStrip.imageRect(height: 25, displaySize: CGSize(width: 1000, height: 1000),
                                                        imageSize: CGSize(width: 2000, height: 1000)))
        XCTAssertEqual(rect, CGRect(x: 0, y: 975, width: 2000, height: 25))
    }

    func testNoStrip() {
        XCTAssertNil(MenuBarStrip.imageRect(height: 0, displaySize: CGSize(width: 10, height: 10),
                                            imageSize: CGSize(width: 10, height: 10)))
        XCTAssertNil(MenuBarStrip.imageRect(height: 5, displaySize: .zero, imageSize: CGSize(width: 10, height: 10)))
    }

    /// The strip fades out downwards over `fadeHeightRatio` menu bar heights: full colour at the
    /// top, fainter further down, and the picture untouched below it.
    func testComposedFadesTheStripDownwards() throws {
        let image = try XCTUnwrap(Self.solid(width: 40, height: 40, gray: 0))
        let strips = DesktopPictureStrips(color: ThemeColor(red: 1, green: 0, blue: 0),
                                          displays: [7: MenuBarStripDisplay(size: CGSize(width: 20, height: 20), menuBarHeight: 5)])
        let composed = try XCTUnwrap(strips.composed(image, display: 7))
        let pixels = try XCTUnwrap(Self.pixels(composed))
        // Row 0 is the top row in memory. 2 pixels a point: a 5 pt bar fades over 15 rows, from 40%.
        let red = { (row: Int) in Int(pixels[(row * 40 + 3) * 4]) }
        XCTAssertEqual(Double(red(0)), 0.4 * 255, accuracy: 12, "40% of the colour at the top")
        XCTAssertEqual(pixels[3 * 4 + 1], 0)
        XCTAssertGreaterThan(red(2), red(8), "fainter further down")
        XCTAssertGreaterThan(red(8), red(13))
        XCTAssertGreaterThan(red(8), 0)
        XCTAssertEqual(red(18), 0, "the picture below the fade is untouched")
        XCTAssertNil(strips.composed(image, display: 8), "a display without geometry is left alone")
    }

    func testApplyRewritesFileInPlace() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "OWEThemingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "desktop.png")
        let image = try XCTUnwrap(Self.solid(width: 16, height: 16, gray: 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let strips = DesktopPictureStrips(color: ThemeColor(red: 0, green: 0, blue: 1),
                                          displays: [1: MenuBarStripDisplay(size: CGSize(width: 16, height: 16), menuBarHeight: 4)])
        try strips.apply(toFileAt: url, display: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let pixels = try XCTUnwrap(Self.pixels(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))))
        XCTAssertEqual(Double(pixels[2]), 0.4 * 255, accuracy: 12, "40% of the strip's colour at the top")
        XCTAssertEqual(pixels[(8 * 16) * 4 + 2], 0, "below the 6-row fade the picture is untouched")
    }

    static func solid(width: Int, height: Int, gray: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(red: gray, green: gray, blue: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func pixels(_ image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }
}
