import ImageIO
import MetalKit
import XCTest
@testable import OpenWallpaperEngine

/// WE's "Take screenshot": the sizes it renders at, and a running scene's current moment drawn
/// again offscreen at that size and saved as a PNG.
@MainActor
final class WallpaperScreenshotTests: XCTestCase {
    func testSizesKeepTheDisplaysShapeWithinTheGPUsLimit() {
        let display = SIMD2(3024, 1964)
        XCTAssertEqual(GSScreenshotResolution.display.pixelSize(display: display, maxSide: 16384), display)
        XCTAssertEqual(GSScreenshotResolution.uhd4K.pixelSize(display: display, maxSide: 16384), SIMD2(3840, 2494))
        XCTAssertEqual(GSScreenshotResolution.uhd8K.pixelSize(display: display, maxSide: 16384), SIMD2(7680, 4988))
        // A portrait display's long side is its height.
        XCTAssertEqual(GSScreenshotResolution.uhd4K.pixelSize(display: SIMD2(1080, 1920), maxSide: 16384), SIMD2(2160, 3840))
        // Never past the GPU's largest texture.
        XCTAssertEqual(GSScreenshotResolution.uhd8K.pixelSize(display: SIMD2(1920, 1080), maxSide: 4096), SIMD2(4096, 2304))
        XCTAssertEqual(GSScreenshotResolution.display.pixelSize(display: .zero, maxSide: 16384), .zero)
    }

    func testFileNamesAreUniqueAndFinderSafe() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "owe-screenshot-names-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(WallpaperScreenshotWriter.fileName(title: "Rain: night/city", date: date, timeZone: TimeZone(identifier: "UTC")!),
                       "Rain- night-city 2027-01-15 at 08.00.00.png")
        let image = try XCTUnwrap(Self.solidImage(width: 4, height: 2))
        let first = try WallpaperScreenshotWriter.write(image, title: "T", to: folder, date: date)
        let second = try WallpaperScreenshotWriter.write(image, title: "T", to: folder, date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2.png"))
    }

    /// The scene path: a fixture scene rendered at a display size, then its screenshot rendered
    /// again at 1920 × 1080 (not the display's 480 × 272 scaled up) and written as a PNG.
    func testAFixtureSceneIsRenderedOffscreenToAPNGOfTheChosenSize() throws {
        let directory = Fixtures.url("Scenes/text-retina")
        defer { Fixtures.removeStoredSettings(for: directory) }
        let project = try JSONDecoder().decode(WEProject.self, from: Data(contentsOf: directory.appending(path: "project.json")))
        let model = SceneContentLoader(wallpaper: WEWallpaper(using: project, where: directory))
        let content = try XCTUnwrap(model.metalContent())
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let points = SIMD2<Float>(480, 272)
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 480, height: 272), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 480, height: 272)
        view.isPaused = true
        let renderer = try XCTUnwrap(SceneMetalRenderer(view: view, scriptServices: nil, screenID: "screenshot-test"))
        defer { renderer.releaseContent() }
        var now: CFTimeInterval = 1000
        renderer.wallTime = { now }
        renderer.setContent(content)
        let deadline = Date().addingTimeInterval(60)
        while !renderer.hasContent, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(renderer.hasContent)
        // A few frames for the pipelines that compile off the render thread.
        for _ in 0..<60 {
            now += 1.0 / 30
            renderer.renderShared([SceneViewport(drawableSize: points, pointSize: points, cursor: nil, frameRateLimit: 30)])
            renderer.lastCommandBuffer?.waitUntilCompleted()
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }

        let captured = expectation(description: "screenshot")
        let box = ImageBox()
        let started = renderer.captureScreenshot(pixelSize: SIMD2(1920, 1080), restoring: []) { image in
            box.image = image
            captured.fulfill()
        }
        XCTAssertTrue(started)
        wait(for: [captured], timeout: 30)
        let image = try XCTUnwrap(box.image)
        XCTAssertNil(renderer.sharedFrame, "a single display's extra frame is freed")

        let folder = FileManager.default.temporaryDirectory.appending(path: "owe-screenshot-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try WallpaperScreenshotWriter.write(image, title: project.title, to: folder)
        XCTAssertEqual(url.pathExtension, "png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let saved = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(saved.width, 1920)
        XCTAssertEqual(saved.height, 1080)
        XCTAssertGreaterThan(Self.litPixels(saved), 1920 * 1080 / 200, "the scene's square and text are in the picture")
    }

    private final class ImageBox: @unchecked Sendable {
        var image: CGImage?
    }

    private static func solidImage(width: Int, height: Int) -> CGImage? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context?.makeImage()
    }

    /// Pixels brighter than near black.
    private static func litPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var lit = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2]) > 60 {
            lit += 1
        }
        return lit
    }
}
