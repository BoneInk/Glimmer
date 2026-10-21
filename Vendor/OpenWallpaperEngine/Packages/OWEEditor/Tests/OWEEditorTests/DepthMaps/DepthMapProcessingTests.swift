import CoreGraphics
import ImageIO
import XCTest
@testable import OWEEditor

/// The depth map's convention and its edge-aware upscale, on synthetic gradient and edge pictures.
final class DepthMapProcessingTests: XCTestCase {
    // MARK: Normalisation

    func testNormalisationStretchesOverZeroToOneWithNearWhite() {
        // Inverse depth rising to the right: the right is nearer, so it is whiter.
        let raw = DepthMapBuffer(width: 5, height: 1, values: [10, 20, 30, 40, 50])
        let depth = DepthMapProcessing.normalized(raw)
        XCTAssertEqual(depth.values, [0, 0.25, 0.5, 0.75, 1])
        let flipped = DepthMapProcessing.normalized(raw, inverseDepth: false)
        XCTAssertEqual(flipped.values, [1, 0.75, 0.5, 0.25, 0], "a distance map is flipped so near stays white")
    }

    func testAFlatMapIsMidGrey() {
        let depth = DepthMapProcessing.normalized(DepthMapBuffer(width: 3, height: 2, repeating: 7))
        XCTAssertEqual(Set(depth.values), [0.5], "no parallax either way")
    }

    func testNonFiniteValuesDontBreakTheRange() {
        let depth = DepthMapProcessing.normalized(DepthMapBuffer(width: 4, height: 1, values: [.nan, 0, 2, .infinity]))
        XCTAssertEqual(depth.values[1], 0)
        XCTAssertEqual(depth.values[2], 1)
        XCTAssertEqual(depth.values[0], 0)
    }

    // MARK: Resampling

    func testBilinearResamplingKeepsAGradient() {
        let small = DepthMapBuffer(width: 2, height: 1, values: [0, 1])
        let large = DepthMapProcessing.resized(small, width: 8, height: 2)
        XCTAssertEqual(large.width, 8)
        XCTAssertEqual(large.height, 2)
        XCTAssertEqual(large[0, 0], 0)
        XCTAssertEqual(large[7, 1], 1)
        for x in 1..<8 { XCTAssertGreaterThanOrEqual(large[x, 0], large[x - 1, 0]) }
    }

    func testBoxMeanAveragesAWindow() {
        let values: [Float] = [0, 0, 0, 0, 9, 0, 0, 0, 0]
        let mean = DepthMapProcessing.boxMean(values, width: 3, height: 3, radius: 1)
        XCTAssertEqual(mean[4], 1, accuracy: 1e-6)
        XCTAssertEqual(mean[0], 9.0 / 4.0, accuracy: 1e-6, "clamped at the corner: a 2×2 window")
    }

    // MARK: The edge-aware upscale

    /// Columns of the middle row caught between near and far.
    private func transitionWidth(_ depth: DepthMapBuffer) -> Int {
        let row = depth.height / 2
        return (0..<depth.width).filter { depth[$0, row] > 0.1 && depth[$0, row] < 0.9 }.count
    }

    func testTheUpscaleFollowsThePicturesEdge() throws {
        let source = DepthMapTestSupport.edge(width: 256, height: 64)
        let guide = try XCTUnwrap(DepthMapBuffer.luminance(of: source))
        // The model's own resolution: 16 × 4, the same edge, as a model sees it.
        var low = DepthMapBuffer(width: 16, height: 4)
        for y in 0..<4 { for x in 0..<16 { low[x, y] = x < 8 ? 0 : 1 } }

        let bilinear = DepthMapProcessing.resized(low, width: 256, height: 64)
        let guided = DepthMapProcessing.upscaled(low, guide: guide)
        XCTAssertEqual(guided.width, 256)
        XCTAssertEqual(guided.height, 64)
        XCTAssertGreaterThan(transitionWidth(bilinear), 8, "stretching alone blurs the edge over a model pixel")
        XCTAssertLessThanOrEqual(transitionWidth(guided), transitionWidth(bilinear) / 3, "the guide snaps it back")
        XCTAssertLessThan(guided[20, 32], 0.05)
        XCTAssertGreaterThan(guided[235, 32], 0.95)
        XCTAssertLessThan(guided[126, 32], guided[129, 32], "near stays on the near side of the edge")
    }

    func testSmoothingKeepsEdgesAndCalmsFlatAreas() throws {
        let source = DepthMapTestSupport.edge(width: 128, height: 32)
        let guide = try XCTUnwrap(DepthMapBuffer.luminance(of: source))
        // A noisy step: flat halves with a ripple.
        var depth = DepthMapBuffer(width: 128, height: 32)
        for y in 0..<32 { for x in 0..<128 { depth[x, y] = (x < 64 ? 0.2 : 0.8) + ((x + y) % 2 == 0 ? 0.05 : -0.05) } }
        XCTAssertEqual(DepthMapProcessing.smoothed(depth, guide: guide, smoothing: 0), depth, "0 leaves the map")
        let smooth = DepthMapProcessing.smoothed(depth, guide: guide, smoothing: 1)
        func ripple(_ map: DepthMapBuffer) -> Float { abs(map[20, 16] - map[21, 16]) }
        XCTAssertLessThan(ripple(smooth), ripple(depth) / 2)
        XCTAssertGreaterThan(smooth[100, 16] - smooth[28, 16], 0.4, "the step survives")
    }

    // MARK: On the GPU

    /// The GPU's upscale and smoothing are the CPU's filters: the same map to within an 8-bit step.
    func testTheGPUsFiltersMatchTheCPUs() throws {
        let gpu = try XCTUnwrap(DepthMapGPUProcessing(), "no Metal device")
        let source = DepthMapTestSupport.image(width: 301, height: 157) { x, y in
            (x - 150) * (x - 150) + (y - 78) * (y - 78) < 60 * 60 ? 0.9 : 0.15 + 0.1 * sin(Double(x + y) / 7)
        }
        let guide = try XCTUnwrap(DepthMapBuffer.luminance(of: source))
        var low = DepthMapBuffer(width: 37, height: 21)
        for y in 0..<21 { for x in 0..<37 { low[x, y] = Float((x - 18) * (x - 18) + (y - 10) * (y - 10) < 64 ? 1 : 0.1 + 0.02 * Double(x % 3)) } }

        func largestDifference(_ a: DepthMapBuffer, _ b: DepthMapBuffer) -> Float {
            zip(a.values, b.values).map { abs($0 - $1) }.max() ?? 0
        }
        let upscaled = DepthMapProcessing.upscaled(low, guide: guide)
        let gpuUpscaled = try gpu.upscaled(low, guide: guide)
        XCTAssertEqual(gpuUpscaled.width, 301)
        XCTAssertEqual(gpuUpscaled.height, 157)
        XCTAssertLessThan(largestDifference(upscaled, gpuUpscaled), 1 / 255)
        for smoothing in [0, 0.25, 1.0] {
            let smoothed = DepthMapProcessing.smoothed(upscaled, guide: guide, smoothing: smoothing)
            XCTAssertLessThan(largestDifference(smoothed, try gpu.smoothed(upscaled, guide: guide, smoothing: smoothing)), 1 / 255,
                              "smoothing \(smoothing)")
        }
    }

    // MARK: Files

    func testTheDepthMapIsAnEightBitGreyPNGAtItsSize() throws {
        var depth = DepthMapBuffer(width: 33, height: 7)
        for x in 0..<33 { for y in 0..<7 { depth[x, y] = Float(x) / 32 } }
        let png = try XCTUnwrap(depth.pngData())
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 33)
        XCTAssertEqual(image.height, 7)
        XCTAssertEqual(image.bitsPerPixel, 8, "r8, as WE's depth slot asks")
        let read = try XCTUnwrap(DepthMapBuffer.gray(of: image))
        XCTAssertEqual(read[0, 3], 0, accuracy: 1 / 255)
        XCTAssertEqual(read[32, 3], 1, accuracy: 1 / 255)
        XCTAssertEqual(read[16, 3], 0.5, accuracy: 2 / 255)
    }

    func testHalfFloatsReadOnEveryArchitecture() {
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0x3c00), 1)
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0xc000), -2)
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0x3800), 0.5)
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0x0000), 0)
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0x7bff), 65504)
        XCTAssertEqual(CoreMLDepthEstimator.halfToFloat(0x0001), powf(2, -24), accuracy: 1e-12)
    }
}
