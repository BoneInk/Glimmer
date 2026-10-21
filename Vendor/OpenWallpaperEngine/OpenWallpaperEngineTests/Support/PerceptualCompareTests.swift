import AppKit
import CoreText
import XCTest

final class PerceptualCompareTests: XCTestCase {
    private func textImage(width: Int = 320, height: Int = 96, offsetX: CGFloat = 0) throws -> PerceptualImage {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.12, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let text = NSAttributedString(string: "Wallpaper 12:34", attributes: [
            .font: font, .foregroundColor: CGColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 16 + offsetX, y: 36)
        CTLineDraw(line, context)
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(PerceptualImage(image))
    }

    private func gradient(width: Int = 128, height: Int = 64, bias: Int = 0) -> PerceptualImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                bytes[o] = UInt8(clamping: x * 2 + bias)
                bytes[o + 1] = UInt8(clamping: y * 3 + bias)
                bytes[o + 2] = UInt8(clamping: 128 + bias)
            }
        }
        return PerceptualImage(width: width, height: height, rgba: bytes)
    }

    func testSSIMOfImageWithItselfIsOne() throws {
        let image = try textImage()
        let value: Double = PerceptualCompare.ssim(image, image)
        XCTAssertEqual(value, 1, accuracy: 1e-6)
        let delta: Double = PerceptualCompare.deltaE99(image, image)
        XCTAssertEqual(delta, 0)
    }

    func testOnePixelShiftOfTextFallsBelowTextBar() throws {
        let reference = try textImage()
        let shifted = try textImage(offsetX: 1)
        let value: Double = PerceptualCompare.ssim(reference, shifted)
        XCTAssertLessThan(value, 0.995)
        let mask = PerceptualMask.edges(of: reference)
        XCTAssertGreaterThan(mask.count, 0)
        let verdict = PerceptualCompare.evaluate(reference: reference, candidate: shifted, kind: .lossy, textMask: mask)
        XCTAssertFalse(verdict.passed, "\(verdict)")
        let text: Double = try XCTUnwrap(verdict.textSSIM)
        XCTAssertLessThan(text, value, "the text region is where a shift shows")
    }

    func testSmallColourShiftPassesLossyAndLargeOneFails() {
        let reference = gradient()
        let candidate = gradient(bias: 1)
        let lossy = PerceptualCompare.evaluate(reference: reference, candidate: candidate, kind: .lossy)
        XCTAssertTrue(lossy.passed, "\(lossy)")
        XCTAssertLessThanOrEqual(lossy.deltaE99, PerceptualCompare.Threshold.lossyDeltaE99)
        let far = gradient(bias: 12)
        let failing = PerceptualCompare.evaluate(reference: reference, candidate: far, kind: .lossy)
        XCTAssertFalse(failing.passed, "\(failing)")
    }

    func testMaskRestrictsMeasurement() throws {
        let reference = try textImage()
        let shifted = try textImage(offsetX: 1)
        var empty = PerceptualMask(width: reference.width, height: reference.height)
        empty.include(CGRect(x: 0, y: 0, width: 8, height: 8))
        let corner: Double = PerceptualCompare.ssim(reference, shifted, mask: empty)
        XCTAssertEqual(corner, 1, accuracy: 1e-4, "an untouched corner stays identical")
    }

    /// Sharma, Wu & Dalal (2005) test data, pairs 1, 7 and 17.
    func testCIEDE2000MatchesPublishedPairs() {
        typealias Lab = PerceptualCompare.Lab
        let cases: [(Lab, Lab, Double)] = [
            (Lab(l: 50, a: 2.6772, b: -79.7751), Lab(l: 50, a: 0, b: -82.7485), 2.0425),
            (Lab(l: 50, a: 0, b: 0), Lab(l: 50, a: -1, b: 2), 2.3669),
            (Lab(l: 50, a: 2.5, b: 0), Lab(l: 73, a: 25, b: -18), 27.1492),
        ]
        for (p, q, expected) in cases {
            let value: Double = PerceptualCompare.ciede2000(p, q)
            XCTAssertEqual(value, expected, accuracy: 1e-4)
        }
    }

    /// A 1080p compare, which every perceptual render check runs at least once, stays within its
    /// budget: about 0.9 s unoptimised on an M-series Mac, so 5 s leaves room for a busy CI runner
    /// without hiding a regression to a much slower compare. An identical pair passes with SSIM 1
    /// and no colour difference.
    func testFullHDCompareCost() throws {
        let width = 1920, height = 1080
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 >> 7) }
        let a = PerceptualImage(width: width, height: height, rgba: bytes)
        let start = CFAbsoluteTimeGetCurrent()
        let verdict = PerceptualCompare.evaluate(reference: a, candidate: a, kind: .lossy)
        let seconds: Double = CFAbsoluteTimeGetCurrent() - start
        XCTAssertTrue(verdict.passed, verdict.description)
        XCTAssertEqual(verdict.ssim, 1, accuracy: 1e-9)
        XCTAssertEqual(verdict.deltaE99, 0, accuracy: 1e-9)
        XCTAssertLessThan(seconds, Self.fullHDCompareBudget, "a 1080p compare took \(seconds) s")
    }

    static let fullHDCompareBudget: Double = 5
}
