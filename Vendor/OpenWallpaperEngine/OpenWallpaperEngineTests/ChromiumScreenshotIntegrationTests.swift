import AppKit
import ImageIO
import XCTest
@testable import OpenWallpaperEngine

/// A screenshot of a page in the real Chromium engine: a solid colour page drawn at its own size
/// and at twice its width, saved as PNGs. Skipped without an installed engine.
@MainActor
final class ChromiumScreenshotIntegrationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(ChromiumEngineInstallation.activeInstall() == nil, "The Chromium engine isn't installed")
        folder = FileManager.default.temporaryDirectory.appending(path: "ChromiumScreenshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<html><body style=\"margin:0;background:#ff0000\"></body></html>"
            .write(to: folder.appending(path: "index.html"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testASolidPageIsSavedAtItsOwnSizeAndAtTwiceItsWidth() async throws {
        let page = ChromiumBrowserPage(startScripts: [], frameRate: 30)
        defer { page.close() }
        let frames = FrameCount()
        page.onFrame = { _ in frames.add() }
        page.resize(width: 200, height: 100, scale: 1)
        page.load(.init(url: WebWallpaperSchemeHandler.url(forRelativePath: "index.html")!, directory: folder))
        waitUntil("the first frame", timeout: 30) { frames.count > 0 }

        for (width, height) in [(200, 100), (400, 200)] {
            let image = try await WallpaperScreenshotService.capture(page, pixelWidth: width)
            let url = try WallpaperScreenshotWriter.write(image, title: "Chromium \(width)", to: folder)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let png = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(png.width, width)
            XCTAssertEqual(png.height, height)
            let (red, green, blue) = try centre(of: png)
            XCTAssertGreaterThan(red, 240, "\(width)")
            XCTAssertLessThan(green, 16, "\(width)")
            XCTAssertLessThan(blue, 16, "\(width)")
        }
    }

    /// The middle pixel in sRGB.
    private func centre(of image: CGImage) throws -> (UInt8, UInt8, UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (pixel[0], pixel[1], pixel[2])
    }
}

private final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func add() { lock.withLock { value += 1 } }
}
