import XCTest
@testable import OWETheming

final class SchemeColorSourceTests: XCTestCase {
    private let project = "0.69 0.27 0.33"

    func testProjectValueWithoutUserChanges() {
        XCTAssertEqual(SchemeColorSource.resolve(running: [:], userSet: [:], projectValue: project),
                       ThemeColor(weString: project))
    }

    func testFollowsUserPropertyChanges() {
        // Saved in the Details panel.
        XCTAssertEqual(SchemeColorSource.resolve(running: [:], userSet: ["schemecolor": "0 0 1"], projectValue: project),
                       ThemeColor(red: 0, green: 0, blue: 1))
        // Changed live (a preset, or an edit not yet saved): the running value wins.
        XCTAssertEqual(SchemeColorSource.resolve(running: ["schemecolor": "1 0 0"], userSet: ["schemecolor": "0 0 1"],
                                                 projectValue: project),
                       ThemeColor(red: 1, green: 0, blue: 0))
        // Other properties don't matter.
        XCTAssertEqual(SchemeColorSource.resolve(running: ["speed": "2"], userSet: [:], projectValue: project),
                       ThemeColor(weString: project))
    }

    func testUnreadableValueFallsBack() {
        XCTAssertEqual(SchemeColorSource.resolve(running: ["schemecolor": "nope"], userSet: [:], projectValue: project),
                       ThemeColor(weString: project))
        XCTAssertNil(SchemeColorSource.resolve(running: [:], userSet: [:], projectValue: nil))
    }

    func testDominantColorPicksTheLargestChromaticCluster() throws {
        let blue = ThemeColor(red: 0.1, green: 0.2, blue: 0.8)
        let orange = ThemeColor(red: 0.9, green: 0.5, blue: 0.1)
        let colors = Array(repeating: blue, count: 700) + Array(repeating: orange, count: 300)
        let dominant = try XCTUnwrap(DominantColor.dominant(of: colors))
        XCTAssertEqual(dominant.red, blue.red, accuracy: 1e-3, "already usable: kept as it is")
        XCTAssertEqual(dominant.blue, blue.blue, accuracy: 1e-3)
        XCTAssertNil(DominantColor.dominant(of: []))
    }

    func testAMostlyWhitePictureWithALittleRedPicksRed() throws {
        let colors = Array(repeating: ThemeColor(red: 0.97, green: 0.97, blue: 0.96), count: 920)
            + Array(repeating: ThemeColor(red: 0.85, green: 0.1, blue: 0.12), count: 80)
        let picked = OKLab(try XCTUnwrap(DominantColor.dominant(of: colors)))
        XCTAssertEqual(picked.hue, OKLab(ThemeColor(red: 0.85, green: 0.1, blue: 0.12)).hue, accuracy: 0.05)
        assertUsable(picked)
    }

    func testABlackAndGrayPictureWithALittleTealPicksTeal() throws {
        let teal = ThemeColor(red: 0.0, green: 0.5, blue: 0.5)
        let colors = Array(repeating: ThemeColor(red: 0.02, green: 0.02, blue: 0.02), count: 600)
            + Array(repeating: ThemeColor(red: 0.45, green: 0.45, blue: 0.45), count: 350)
            + Array(repeating: teal, count: 50)
        let picked = OKLab(try XCTUnwrap(DominantColor.dominant(of: colors)))
        XCTAssertEqual(picked.hue, OKLab(teal).hue, accuracy: 0.05)
        assertUsable(picked)
    }

    func testAGrayscalePictureFallsBackToNeutral() throws {
        let colors = (0..<1000).map { index -> ThemeColor in
            let gray = Double(index % 256) / 255
            return ThemeColor(red: gray, green: gray, blue: gray)
        }
        XCTAssertEqual(DominantColor.dominant(of: colors), DominantColor.neutral)
        XCTAssertEqual(AccentPalette.nearest(to: DominantColor.neutral), .graphite)
        let image = try XCTUnwrap(MenuBarStripTests.solid(width: 64, height: 64, gray: 0.5))
        XCTAssertEqual(DominantColor.of(image), DominantColor.neutral)
    }

    func testChromaticPicksAreAlwaysWithinTheBounds() {
        for hueStep in 0..<24 {
            for lightness in [0.05, 0.3, 0.6, 0.95] {
                for chroma in [0.035, 0.1, 0.3] {
                    let source = OKLab(lightness: lightness, chroma: chroma, hue: Double(hueStep) / 24 * 2 * .pi)
                    let usable = DominantColor.usable(source)
                    XCTAssertTrue(usable.isInSRGBGamut)
                    assertUsable(OKLab(usable.themeColor))
                    XCTAssertEqual(usable.hue, source.hue, accuracy: 1e-6, "the hue is kept")
                }
            }
        }
    }

    func testTheCacheComputesEachFileOnce() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "dominant-\(UUID().uuidString).txt")
        try Data("a".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var calls = 0
        let cache = DominantColorCache { _ in
            calls += 1
            return ThemeColor(red: 1, green: 0, blue: 0)
        }
        XCTAssertNotNil(cache.color(fileAt: url))
        XCTAssertNotNil(cache.color(fileAt: url))
        XCTAssertEqual(calls, 1)
        try Data("bb".utf8).write(to: url)
        _ = cache.color(fileAt: url)
        XCTAssertEqual(calls, 2, "a new version of the file is looked at again")
    }

    private func assertUsable(_ color: OKLab, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(color.lightness, DominantColor.outputLightness.lowerBound - 0.01, file: file, line: line)
        XCTAssertLessThanOrEqual(color.lightness, DominantColor.outputLightness.upperBound + 0.01, file: file, line: line)
        XCTAssertGreaterThanOrEqual(color.chroma, DominantColor.minimumOutputChroma - 0.01, file: file, line: line)
    }

    func testSettingsDefaultsAreOffAndDecodeTolerantly() throws {
        let defaults = ThemingSettings()
        XCTAssertFalse(defaults.isEnabled || defaults.menuBar || defaults.accentColor || defaults.tintedIcons
                       || defaults.folderColor || defaults.usesDominantColor)
        XCTAssertTrue(defaults.restoresOnQuit)
        let decoded = try JSONDecoder().decode(ThemingSettings.self,
                                               from: Data(#"{"isEnabled":true,"menuBar":"bad"}"#.utf8))
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertFalse(decoded.menuBar)
    }
}
