import XCTest
@testable import OpenWallpaperEngine

/// The filter sidebar draws each filter generically: option `i` is the checkbox for bit `1 << i`,
/// and All/None set the filter's own `all` and `none`. Those have to agree, or All would tick
/// boxes that don't exist or leave some unticked.
final class FilterResultsModelTests: XCTestCase {
    private func assertCheckboxesCoverAll<Option: FilterResultsModel>(_: Option.Type,
                                                                    file: StaticString = #filePath,
                                                                    line: UInt = #line) {
        let checkboxes = Option.optionKeys.indices.reduce(into: Option.none) { bits, index in
            bits.insert(Option(rawValue: 1 << index))
        }
        XCTAssertEqual(checkboxes, Option.all, "\(Option.self)", file: file, line: line)
        XCTAssertTrue(Option.none.isEmpty, "\(Option.self)", file: file, line: line)
    }

    func testAllSelectsExactlyTheCheckboxes() {
        assertCheckboxesCoverAll(FRShowOnly.self)
        assertCheckboxesCoverAll(FRType.self)
        assertCheckboxesCoverAll(FRCategory.self)
        assertCheckboxesCoverAll(FRAgeRating.self)
        assertCheckboxesCoverAll(FRWidescreenResolution.self)
        assertCheckboxesCoverAll(FRUltraWidescreenResolution.self)
        assertCheckboxesCoverAll(FRDualscreenResolution.self)
        assertCheckboxesCoverAll(FRTriplescreenResolution.self)
        assertCheckboxesCoverAll(FRPortraitScreenResolution.self)
        assertCheckboxesCoverAll(FRMiscResolution.self)
        assertCheckboxesCoverAll(FRSource.self)
        assertCheckboxesCoverAll(FRTag.self)
    }

    /// Option `i` is stored as bit `1 << i`, so the keys' order is part of the saved filters.
    func testOptionKeysKeepTheirStoredOrder() {
        XCTAssertEqual(FRShowOnly.optionKeys,
                       ["Approved", "My Favourites", "Mobile Compatible", "Audio Responsive", "Customizable"])
        XCTAssertEqual(FRType.optionKeys, ["Scene", "Video", "Web", "Application"])
        XCTAssertEqual(FRAgeRating.optionKeys, ["Everyone", "Partial Nudity", "Mature"])
        XCTAssertEqual(FRSource.optionKeys, ["Official", "Workshop", "MyWallpapers"])
        XCTAssertEqual(FRTag.optionKeys.first, "Abstract")
        XCTAssertEqual(FRTag.optionKeys.last, "UnspecifiedGenre")
    }

    /// The label is shown, the key never is.
    func testLabelsAreSeparateFromKeys() {
        let pixelArt = FRTag.options[FRTag.optionKeys.firstIndex(of: "PixelArt")!]
        XCTAssertEqual(String(localized: pixelArt.label), "Pixel Art")
        XCTAssertEqual(String(localized: FilterOption(key: "MyWallpapers").label), "My Wallpapers")
        XCTAssertEqual(FRShowOnly.options.map(\.systemImage).compactMap { $0 }.count, FRShowOnly.options.count)
    }
}
