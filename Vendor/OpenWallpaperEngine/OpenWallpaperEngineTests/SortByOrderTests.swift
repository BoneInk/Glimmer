import XCTest
@testable import OpenWallpaperEngine

/// The library's orders compare the sorted value in both directions; WE's Favorite and Last
/// Updated sorts order equal values by title.
final class SortByOrderTests: XCTestCase {
    func testFileSizesSortByTheirSizeInBothDirections() {
        // Titles in the opposite order to the sizes, so comparing titles would give the wrong order.
        let sizes: [(title: String, size: Int)] = [("A", 30), ("B", 10), ("C", 20)]
        let increasing = sizes.sorted { InstalledLibraryModel.precedes($0.size, $1.size, in: .increase) }
        let decreasing = sizes.sorted { InstalledLibraryModel.precedes($0.size, $1.size, in: .decrease) }
        XCTAssertEqual(increasing.map(\.size), [30, 20, 10])
        XCTAssertEqual(decreasing.map(\.size), [10, 20, 30])
    }

    func testEqualValuesNeverPrecedeEachOther() {
        XCTAssertFalse(InstalledLibraryModel.precedes(5, 5, in: .increase))
        XCTAssertFalse(InstalledLibraryModel.precedes(5, 5, in: .decrease))
    }

    func testRatingsSortEveryoneQuestionableMature() {
        let ratings: [String?] = ["Mature", nil, "Questionable", "Everyone"]
        let decreasing = ratings.sorted {
            InstalledLibraryModel.precedes(InstalledLibraryModel.ratingRank($0), InstalledLibraryModel.ratingRank($1), in: .decrease)
        }
        XCTAssertEqual(decreasing, [nil, "Everyone", "Questionable", "Mature"])
        XCTAssertEqual(InstalledLibraryModel.ratingRank(" mature"), InstalledLibraryModel.ratingRank("Mature"))
    }

    func testKeyedSortsPutTheLargerKeyFirstAndTiesByTitleAsWE() {
        let items: [(key: Int, title: String)] = [(0, "b"), (1, "z"), (0, "a"), (1, "c")]
        let ascending = items.sorted { InstalledLibraryModel.precedes($0, $1, in: .increase) }
        XCTAssertEqual(ascending.map(\.title), ["c", "z", "a", "b"])
        let descending = items.sorted { InstalledLibraryModel.precedes($0, $1, in: .decrease) }
        XCTAssertEqual(descending.map(\.title), ["b", "a", "z", "c"])
        XCTAssertFalse(InstalledLibraryModel.precedes((1, "a"), (1, "a"), in: .increase))
    }

    func testLastUpdatedIsSteamsTimeElseTheFolderDateAndNoneForLocalWallpapers() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "SortByOrderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workshop = root.appending(path: "123456"), local = root.appending(path: "My Wallpaper")
        for folder in [workshop, local] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: workshop.path)
        let workshopWallpaper = WEWallpaper(using: .invalid, where: workshop)
        let localWallpaper = WEWallpaper(using: .invalid, where: local)

        XCTAssertEqual(InstalledLibraryModel.lastUpdated(of: workshopWallpaper) { $0 == "123456" ? 1_750_000_000 : nil },
                       1_750_000_000)
        XCTAssertEqual(InstalledLibraryModel.lastUpdated(of: workshopWallpaper) { _ in nil }, 1_700_000_000)
        XCTAssertEqual(InstalledLibraryModel.lastUpdated(of: localWallpaper) { _ in 1_750_000_000 }, 0)
    }
}
