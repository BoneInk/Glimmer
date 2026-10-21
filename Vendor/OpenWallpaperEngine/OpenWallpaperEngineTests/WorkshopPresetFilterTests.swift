import XCTest
@testable import OpenWallpaperEngine

/// WE's Category filter (Wallpaper / Preset): installed preset items and Workshop items tagged
/// `Preset`, with the base they depend on.
final class WorkshopPresetFilterTests: XCTestCase {
    private let library = Fixtures.url("Library/preset-item")

    func testInstalledPresetItemsAreInThePresetCategory() throws {
        let preset = try XCTUnwrap(InstalledLibrary.wallpaper(at: library.appending(path: "3332091404"), hiding: []))
        let base = try XCTUnwrap(InstalledLibrary.wallpaper(at: library.appending(path: "3122339805"), hiding: []))
        XCTAssertEqual(FRCategory.of(preset), .preset)
        XCTAssertEqual(FRCategory.of(base), .wallpaper)
        let onlyPresets: FRCategory = .preset
        XCTAssertTrue(onlyPresets.contains(FRCategory.of(preset)))
        XCTAssertFalse(onlyPresets.contains(FRCategory.of(base)))
    }

    func testTheCategoryOptionsAreWEsTags() {
        XCTAssertEqual(FRCategory.optionKeys, ["Wallpaper", "Preset"])
        XCTAssertEqual(FRCategory.all, [.wallpaper, .preset])
    }

    func testCheckingPresetsExcludesWallpapersOnSteam() {
        var filter = WorkshopFilter()
        filter.categories = ["Preset"]
        let query = WorkshopQuery(filter)
        XCTAssertTrue(query.excludedTags.contains("Wallpaper"))
        XCTAssertFalse(query.excludedTags.contains("Preset"))
        XCTAssertNotEqual(filter.cacheKey, WorkshopFilter().cacheKey)

        let items = WorkshopAPIService.queryItems(text: "", filter: query, sortOrder: .default, page: 1, perPage: 20)
        XCTAssertTrue(items.contains { $0.name.hasPrefix("excludedtags[") && $0.value == "Wallpaper" })
        XCTAssertTrue(items.contains(URLQueryItem(name: "return_children", value: "true")))
    }

    func testBothOrNoCategoriesDoNotFilter() {
        var filter = WorkshopFilter()
        filter.categories = ["Wallpaper", "Preset"]
        XCTAssertFalse(WorkshopQuery(filter).excludedTags.contains { WorkshopTags.categories.contains($0) })
    }

    func testAPresetResultCarriesItsBaseAsItsDependency() throws {
        let data = try Data(contentsOf: Fixtures.url("Workshop/api/query-files.json"))
        let items = try WorkshopAPIService.parseItems(from: data)
        let preset = try XCTUnwrap(items.first { $0.id == "3100000002" })
        XCTAssertTrue(preset.isPreset)
        XCTAssertEqual(preset.dependencyIds, ["3100000001"])
        let wallpaper = try XCTUnwrap(items.first { $0.id == "3100000001" })
        XCTAssertFalse(wallpaper.isPreset)
        XCTAssertNil(items.first { $0.id == "3100000003" }?.dependencyIds)
    }
}
