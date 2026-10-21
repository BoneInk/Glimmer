import XCTest
@testable import OWESceneEditing

/// The image tools' OpenCV operations: kernels, borders, filters, resizing, distances, inpainting.
final class ImagePlaneTests: XCTestCase {
    func testGaussianKernelsAreOpenCVs() {
        XCTAssertEqual(ImagePlane.gaussianKernel(size: 3), [0.25, 0.5, 0.25])
        XCTAssertEqual(ImagePlane.gaussianKernel(size: 5), [0.0625, 0.25, 0.375, 0.25, 0.0625])
        let large = ImagePlane.gaussianKernel(size: 13)
        XCTAssertEqual(large.count, 13)
        XCTAssertEqual(large.reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(large[0], large[12], accuracy: 1e-7)
        // sigma 0.3 × (6 − 1) + 0.8 = 2.3.
        let expected: Float = exp(-36 / (2 * 2.3 * 2.3)) / exp(0)
        XCTAssertEqual(large[0] / large[6], expected, accuracy: 1e-5)
    }

    func testSobelKernelsAreOpenCVs() {
        XCTAssertEqual(ImagePlane.sobelKernel(order: 1, size: 3), [-1, 0, 1])
        XCTAssertEqual(ImagePlane.sobelKernel(order: 0, size: 3), [1, 2, 1])
        XCTAssertEqual(ImagePlane.sobelKernel(order: 1, size: 5), [-1, -2, 0, 2, 1])
        XCTAssertEqual(ImagePlane.sobelKernel(order: 0, size: 5), [1, 4, 6, 4, 1])
        XCTAssertEqual(ImagePlane.sobelKernel(order: 1, size: 7), [-1, -4, -5, 0, 5, 4, 1])
        XCTAssertEqual(ImagePlane.sobelKernel(order: 1, size: 13).count, 13)
    }

    func testBorderModes() {
        let plane = ImagePlane(width: 3, height: 1, pixels: [1, 2, 3])
        func middleRow(_ padded: ImagePlane, _ border: Int) -> [Float] { Array(padded.pixels[border * padded.width..<(border + 1) * padded.width]) }
        XCTAssertEqual(middleRow(plane.padded(by: 2, mode: .replicate), 2), [1, 1, 1, 2, 3, 3, 3])
        XCTAssertEqual(middleRow(plane.padded(by: 2, mode: .reflect101), 2), [3, 2, 1, 2, 3, 2, 1])
        XCTAssertEqual(middleRow(plane.padded(by: 1, mode: .zero), 1), [0, 1, 2, 3, 0])
        XCTAssertEqual(plane.padded(by: 1, mode: .zero).pixels.prefix(5), [0, 0, 0, 0, 0])
    }

    func testSobelOfARampIsItsSlope() {
        var ramp = ImagePlane(width: 16, height: 8)
        for y in 0..<8 { for x in 0..<16 { ramp[x, y] = Float(x) } }
        let gx = ramp.sobel(dx: 1, dy: 0, size: 3)
        let gy = ramp.sobel(dx: 0, dy: 1, size: 3)
        // [-1 0 1] × [1 2 1]: 2 per step, times 4.
        XCTAssertEqual(gx[8, 4], 8, accuracy: 1e-4)
        XCTAssertEqual(gy[8, 4], 0, accuracy: 1e-4)
        // Reflected at the edge: no slope there.
        XCTAssertEqual(gx[0, 4], 0, accuracy: 1e-4)
        // A long kernel leaves a flat direction exactly flat.
        XCTAssertEqual(ramp.sobel(dx: 0, dy: 1, size: 13).minMax.max, 0)
        XCTAssertEqual(ramp.sobel(dx: 0, dy: 1, size: 13).minMax.min, 0)
    }

    func testGaussianBlurKeepsAFlatPlaneAndSpreadsAnImpulse() {
        let flat = ImagePlane(width: 20, height: 10, value: 0.5)
        XCTAssertEqual(flat.gaussianBlurred(size: 9).pixels.max() ?? 0, 0.5, accuracy: 1e-5)
        var impulse = ImagePlane(width: 9, height: 9)
        impulse[4, 4] = 1
        let blurred = impulse.gaussianBlurred(size: 3)
        XCTAssertEqual(blurred[4, 4], 0.25, accuracy: 1e-6)
        XCTAssertEqual(blurred[3, 4], 0.125, accuracy: 1e-6)
        XCTAssertEqual(blurred[3, 3], 0.0625, accuracy: 1e-6)
    }

    func testBilinearResizeAlignsPixelCentres() {
        let plane = ImagePlane(width: 2, height: 1, pixels: [0, 1])
        let up = plane.resized(width: 4, height: 1)
        // cv::resize: (x + 0.5) / 2 − 0.5 → −0.25, 0.25, 0.75, 1.25.
        XCTAssertEqual(up.pixels, [0, 0.25, 0.75, 1])
        XCTAssertEqual(up.resized(width: 2, height: 1).pixels, [0.125, 0.875])
    }

    func testDistanceTransformIsEuclidean() {
        let plane = DistanceTransform.distances(width: 7, height: 7) { $0 != 3 * 7 + 3 }
        XCTAssertEqual(plane[3, 3], 0)
        XCTAssertEqual(plane[6, 3], 3, accuracy: 1e-5)
        XCTAssertEqual(plane[6, 6], (18 as Float).squareRoot(), accuracy: 1e-5)
        XCTAssertEqual(plane[4, 5], (5 as Float).squareRoot(), accuracy: 1e-5)
    }

    func testInpaintingFillsAHoleFromAround() {
        var plane = ImagePlane(width: 12, height: 12, value: 0.75)
        var unknown = [Bool](repeating: false, count: 144)
        for y in 4..<8 { for x in 4..<8 { plane[x, y] = 0; unknown[y * 12 + x] = true } }
        let filled = Inpainting.telea([plane], unknown: unknown, radius: 2)[0]
        for y in 4..<8 { for x in 4..<8 { XCTAssertEqual(filled[x, y], 0.75, accuracy: 1e-4) } }
        // Known pixels are kept.
        XCTAssertEqual(filled[0, 0], 0.75)
    }

    func testNormalizeMapsTheRange() {
        let plane = ImagePlane(width: 3, height: 1, pixels: [2, 4, 6])
        XCTAssertEqual(plane.normalized().pixels, [0, 0.5, 1])
        XCTAssertEqual(plane.normalized(-1, 1).pixels, [-1, 0, 1])
        XCTAssertEqual(ImagePlane(width: 2, height: 1, value: 3).normalized().pixels, [0, 0])
    }
}
