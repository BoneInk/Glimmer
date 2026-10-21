import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// A layer's pixels are dropped once uploaded; the sizes the renderer still reads must survive.
final class SceneUploadedTextureTests: XCTestCase {
    private func image(width: Int, height: Int) throws -> NSImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cgImage = try XCTUnwrap(context.makeImage())
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    func testUploadedImageKeepsItsSizes() throws {
        let source = SceneMetalTextureSource.image(try image(width: 48, height: 20))
        let uploaded = source.uploaded
        guard case .uploaded = uploaded else { return XCTFail("an image gives way to its sizes") }
        XCTAssertEqual(uploaded.pixelSize, source.pixelSize)
        XCTAssertNil(uploaded.contentSize)
        XCTAssertEqual(uploaded.unsizedLayerSize, source.unsizedLayerSize)
        XCTAssertEqual(uploaded.sheetPixelSize, source.sheetPixelSize)
    }

    func testUploadingTwiceChangesNothing() throws {
        let once = SceneMetalTextureSource.image(try image(width: 8, height: 8)).uploaded
        let twice = once.uploaded
        guard case let .uploaded(a) = once, case let .uploaded(b) = twice else { return XCTFail() }
        XCTAssertEqual(a, b)
    }
}
