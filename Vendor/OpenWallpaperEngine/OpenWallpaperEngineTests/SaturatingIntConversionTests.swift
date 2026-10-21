import XCTest
@testable import OpenWallpaperEngine

/// `Int(saturating:in:)`: float-to-integer conversion of values read from wallpaper files never
/// stops the process.
final class SaturatingIntConversionTests: XCTestCase {
    func testFiniteValuesTruncateTowardZero() {
        XCTAssertEqual(Int(saturating: 2.9), 2)
        XCTAssertEqual(Int(saturating: -2.9), -2)
        XCTAssertEqual(Int(saturating: Float(7.5).rounded()), 8)
        XCTAssertEqual(Int(saturating: 0.0), 0)
    }

    func testNaNBecomesZeroInsideTheRange() {
        XCTAssertEqual(Int(saturating: Double.nan), 0)
        XCTAssertEqual(Int(saturating: Float.nan, in: 1...10), 1)
        XCTAssertEqual(Int(saturating: Double.nan, in: -10...(-1)), -1)
    }

    func testInfinitiesAndOutOfRangeValuesClamp() {
        XCTAssertEqual(Int(saturating: Double.infinity), Int.max)
        XCTAssertEqual(Int(saturating: -Double.infinity), Int.min)
        XCTAssertEqual(Int(saturating: Float.infinity), Int.max)
        XCTAssertEqual(Int(saturating: 1e300), Int.max)
        XCTAssertEqual(Int(saturating: -1e300), Int.min)
        XCTAssertEqual(Int(saturating: Double(Int.max)), Int.max, "2^63 is just outside Int")
        XCTAssertEqual(Int(saturating: Float(1e20)), Int.max)
    }

    func testRangesBoundTheResult() {
        XCTAssertEqual(Int(saturating: 300.0, in: 0...255), 255)
        XCTAssertEqual(Int(saturating: -3.0, in: 0...255), 0)
        XCTAssertEqual(Int(saturating: 42.0, in: 0...255), 42)
        XCTAssertEqual(Int(saturating: Float(16_777_217), in: 0...16_777_216), 16_777_216)
    }
}
