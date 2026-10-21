import XCTest
import AppKit
@testable import OpenWallpaperEngine

/// An image layer draws its .tex image, not the padding of the allocation around it.
final class TexContentCropTests: XCTestCase {
    func testPaddedAllocationIsCroppedToTheImage() {
        let texture = TEXCompressedTexture(format: 0, width: 2048, height: 1024, data: [],
                                           contentWidth: 1920, contentHeight: 1000)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(texture), SIMD2(1920.0 / 2048, 1000.0 / 1024))
        XCTAssertEqual(SceneMetalTextureSource.dxt(texture).contentSize, SIMD2(1920, 1000))
    }

    /// Risks #13 and I9: unsized layers are sized in the image's pixels. A 144-dpi PNG reports
    /// half its pixels as its `NSImage.size`, which would halve the layer (and its sprite frames).
    func testLayerSizeIsInPixelsWhateverTheImageDPI() throws {
        let pixels = [UInt8](repeating: 255, count: 64 * 32 * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: 64, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let retina = NSImage(cgImage: cgImage, size: NSSize(width: 32, height: 16))
        XCTAssertEqual(SceneMetalTextureSource.image(retina).pixelSize, SIMD2(64, 32))
        let animated = TEXAnimatedImages(images: [retina], frames: [])
        XCTAssertEqual(SceneMetalTextureSource.animated(animated).pixelSize, SIMD2(64, 32))
        let padded = TEXCompressedTexture(format: 7, width: 128, height: 64, data: [], contentWidth: 100, contentHeight: 50)
        XCTAssertEqual(SceneMetalTextureSource.dxt(padded).pixelSize, SIMD2(100, 50))
    }

    func testUnpaddedOrUnknownContentKeepsTheWholeTexture() {
        let exact = TEXCompressedTexture(format: 0, width: 64, height: 64, data: [], contentWidth: 64, contentHeight: 64)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(exact), SIMD2(1, 1))
        let unknown = TEXCompressedTexture(format: 0, width: 64, height: 64, data: [], contentWidth: 0, contentHeight: 0)
        XCTAssertEqual(SceneMetalRenderer.contentUVExtent(unknown), SIMD2(1, 1))
    }
}
