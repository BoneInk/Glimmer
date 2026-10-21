import XCTest
@testable import OWETheming

final class ThemeColorTests: XCTestCase {
    func testParsesWESchemeColor() throws {
        let color = try XCTUnwrap(ThemeColor(weString: "0.69 0.27 0.33"))
        XCTAssertEqual(color.red, 0.69, accuracy: 1e-9)
        XCTAssertEqual(color.green, 0.27, accuracy: 1e-9)
        XCTAssertEqual(color.blue, 0.33, accuracy: 1e-9)
    }

    func testReadsZeroTo255AndClamps() throws {
        let color = try XCTUnwrap(ThemeColor(weString: "255 128 0"))
        XCTAssertEqual(color.red, 1, accuracy: 1e-9)
        XCTAssertEqual(color.green, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(ThemeColor(red: -1, green: 2, blue: .nan), ThemeColor(red: 0, green: 1, blue: 0))
    }

    func testRejectsWhatIsNotThreeNumbers() {
        XCTAssertNil(ThemeColor(weString: ""))
        XCTAssertNil(ThemeColor(weString: "0.5 0.5"))
        XCTAssertNil(ThemeColor(weString: "red green blue"))
        XCTAssertNil(ThemeColor(weString: "0.1 0.2 x"))
    }

    func testComponentStringIsLocaleIndependent() {
        XCTAssertEqual(ThemeColor(red: 0.5, green: 0.25, blue: 1).componentString, "0.500000 0.250000 1.000000")
    }

    func testNearestPaletteEntry() {
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.1, green: 0.4, blue: 0.95)), .blue)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.85, green: 0.15, blue: 0.2)), .red)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.95, green: 0.55, blue: 0.1)), .orange)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 1, green: 0.85, blue: 0.1)), .yellow)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.3, green: 0.7, blue: 0.3)), .green)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.55, green: 0.2, blue: 0.6)), .purple)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.95, green: 0.4, blue: 0.65)), .pink)
        XCTAssertEqual(AccentPalette.nearest(to: ThemeColor(red: 0.5, green: 0.5, blue: 0.52)), .graphite)
        // Every entry maps to itself.
        for entry in AccentPalette.allCases { XCTAssertEqual(AccentPalette.nearest(to: entry.color), entry) }
    }

    func testPaletteValuesAreMacOSIntegers() {
        XCTAssertEqual(AccentPalette.graphite.rawValue, -1)
        XCTAssertEqual(AccentPalette.red.rawValue, 0)
        XCTAssertEqual(AccentPalette.blue.rawValue, 4)
        XCTAssertEqual(AccentPalette.pink.rawValue, 6)
    }

    func testHighlightIsALightCustomColor() {
        let value = HighlightColor.preferenceValue(for: ThemeColor(red: 0, green: 0.478, blue: 1))
        XCTAssertTrue(value.hasSuffix(" Other"))
        let parts = value.split(separator: " ").prefix(3).compactMap { Double($0) }
        XCTAssertEqual(parts[0], 0.7, accuracy: 0.001)
        XCTAssertEqual(parts[1], 0.8434, accuracy: 0.001)
        XCTAssertEqual(parts[2], 1, accuracy: 0.001)
    }

    func testOKLabOfWhiteAndBlack() {
        XCTAssertEqual(OKLab(.white).lightness, 1, accuracy: 1e-3)
        XCTAssertEqual(OKLab(.white).chroma, 0, accuracy: 1e-3)
        XCTAssertEqual(OKLab(ThemeColor(red: 0, green: 0, blue: 0)).lightness, 0, accuracy: 1e-6)
    }
}
