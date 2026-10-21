import Observation
import XCTest
@testable import OpenWallpaperEngine

/// The Installed tab's filters, sorting and tile size are kept under the keys and raw values
/// `@AppStorage` used, so the filters saved by earlier versions still load.
@MainActor
final class FilterResultsViewModelTests: XCTestCase {
    private let keys = ["FRShowOnly", "FRType", "FRCategory", "FRAgeRating", "FRWidescreenResolution", "FRUltraWidescreenResolution", "FRDualscreenResolution", "FRTriplescreenResolution", "FRPortraitScreenResolution", "FRMiscResolution", "FRSource", "FRTag",
                                "SortingBy", "SortingSequence", "ExplorerIconSize", "FilterReveal"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys { saved[key] = UserDefaults.app.object(forKey: key) }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.app.set(value, forKey: key) } else { UserDefaults.app.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testLoadsSavedFiltersAndDefaultsTheRest() {
        UserDefaults.app.set(FRType.video.rawValue, forKey: "FRType")
        UserDefaults.app.set(FRShowOnly.myFavourites.rawValue, forKey: "FRShowOnly")
        UserDefaults.app.removeObject(forKey: "FRTag")
        let filters = FilterResultsViewModel()
        XCTAssertEqual(filters.type, .video)
        XCTAssertEqual(filters.showOnly, .myFavourites)
        XCTAssertEqual(filters.tag, .all)
    }

    func testChangesAreSavedAndAnnounced() {
        let filters = FilterResultsViewModel()
        var changes = 0
        filters.onChange = { changes += 1 }
        filters.type = [.scene, .web]
        XCTAssertEqual(UserDefaults.app.object(forKey: "FRType") as? Int, FRType([.scene, .web]).rawValue)
        filters.reset()
        XCTAssertEqual(filters.showOnly, .none)
        XCTAssertEqual(filters.type, .all)
        XCTAssertEqual(UserDefaults.app.object(forKey: "FRShowOnly") as? Int, 0)
        XCTAssertEqual(changes, 13)
    }

    func testSortingAndTileSizeKeepTheirStoredForm() {
        UserDefaults.app.set(WEWallpaperSortingMethod.fileSize.rawValue, forKey: "SortingBy")
        UserDefaults.app.set(WEWallpaperSortingSequence.decrease.rawValue, forKey: "SortingSequence")
        UserDefaults.app.set(Double(125), forKey: "ExplorerIconSize")
        let model = ContentViewModel()
        XCTAssertEqual(model.library.sortingBy, .fileSize)
        XCTAssertEqual(model.library.sortingSequence, .decrease)
        XCTAssertEqual(model.navigation.explorerIconSize, 125)

        model.library.sortingBy = .rating
        model.navigation.explorerIconSize = 150
        model.navigation.isFilterReveal = true
        XCTAssertEqual(UserDefaults.app.string(forKey: "SortingBy"), WEWallpaperSortingMethod.rating.rawValue)
        XCTAssertEqual(UserDefaults.app.double(forKey: "ExplorerIconSize"), 150)
        XCTAssertTrue(UserDefaults.app.bool(forKey: "FilterReveal"))
    }

    /// A view answered from the list's memo still observes the filters, search and sorting, so it
    /// redraws when they change.
    func testInstalledListObservesItsInputs() {
        let model = ContentViewModel()
        final class Flag: @unchecked Sendable { var isSet = false }
        func observeChange(_ change: () -> Void) -> Bool {
            _ = model.library.displayedWallpapers // fills the memo
            let changed = Flag()
            withObservationTracking { _ = model.library.displayedWallpapers } onChange: { changed.isSet = true }
            change()
            return changed.isSet
        }
        XCTAssertTrue(observeChange { model.filters.type = .scene })
        XCTAssertTrue(observeChange { model.library.searchText = "x" })
        XCTAssertTrue(observeChange { model.library.sortingSequence = .decrease })
        XCTAssertTrue(observeChange { model.refresh() })
        XCTAssertFalse(observeChange { model.navigation.isDetailsReveal.toggle() })
        XCTAssertFalse(observeChange { model.presentation.isDisplaySettingsReveal = true })
    }
}
