import AppKit
import XCTest
@testable import OpenWallpaperEngine

/// Finder's click selection, shared by the Installed, Workshop and Discover grids, and the
/// Discover rows' ⇧-click ranges, which reached only into the Workshop tab's page before.
@MainActor
final class ClickSelectionTests: XCTestCase {
    func testModifiersPickTheKind() {
        XCTAssertEqual(ClickSelection.kind(of: []), .replace)
        XCTAssertEqual(ClickSelection.kind(of: .shift), .extend)
        XCTAssertEqual(ClickSelection.kind(of: .command), .toggle)
        XCTAssertEqual(ClickSelection.kind(of: .control), .toggle)
        XCTAssertEqual(ClickSelection.kind(of: [.command, .shift]), .toggle, "⌘ wins")
        XCTAssertEqual(ClickSelection.kind(of: [.shift, .capsLock]), .extend, "other keys don't count")
    }

    func testToggleAndRangeFromTheAnchor() {
        let order = ["a", "b", "c", "d", "e"]
        var selected = Set<String>()
        var anchor: String?
        XCTAssertFalse(ClickSelection.apply(.replace, on: "b", in: order, selected: &selected, anchor: &anchor),
                       "a plain click is the tab's")
        XCTAssertTrue(ClickSelection.apply(.extend, on: "b", in: order, selected: &selected, anchor: &anchor))
        XCTAssertEqual(selected, ["b"], "no anchor yet: just it")
        XCTAssertEqual(anchor, "b")
        ClickSelection.apply(.extend, on: "d", in: order, selected: &selected, anchor: &anchor)
        XCTAssertEqual(selected, ["b", "c", "d"])
        ClickSelection.apply(.extend, on: "a", in: order, selected: &selected, anchor: &anchor)
        XCTAssertEqual(selected, ["a", "b"], "redrawn from the same anchor")
        ClickSelection.apply(.toggle, on: "e", in: order, selected: &selected, anchor: &anchor)
        XCTAssertEqual(selected, ["a", "b", "e"])
        ClickSelection.apply(.toggle, on: "a", in: order, selected: &selected, anchor: &anchor)
        XCTAssertEqual(selected, ["b", "e"])
        XCTAssertEqual(anchor, "a")
        ClickSelection.apply(.extend, on: "c", in: order, selected: &selected, anchor: &anchor)
        XCTAssertEqual(selected, ["a", "b", "c"])
    }

    func testDiscoverRowsSelectRanges() throws {
        let model = try workshop()
        let row = (1...5).map(Self.item)
        XCTAssertTrue(model.items.isEmpty, "the Workshop tab's page holds none of the row")

        model.selectItem(row[1], in: row, kind: .replace)
        XCTAssertEqual(model.selectedItemIds, ["2"])
        model.selectItem(row[3], in: row, kind: .extend)
        XCTAssertEqual(model.selectedItemIds, ["2", "3", "4"])
        model.selectItem(row[4], in: row, kind: .toggle)
        XCTAssertEqual(model.selectedItemIds, ["2", "3", "4", "5"])
        model.selectItem(row[0], in: row, kind: .replace)
        XCTAssertEqual(model.selectedItemIds, ["1"])
    }

    /// Select All in Discover: the list See More opened, else every row of the home once.
    func testSelectAllTakesWhatDiscoverShows() async throws {
        let week = try XCTUnwrap(WorkshopDiscover.home.first { $0.id == "popular-week" })
        let rated = try XCTUnwrap(WorkshopDiscover.home.first { $0.id == "top-rated" })
        let discover = WorkshopDiscoverViewModel(sections: [week, rated], fetch: { section, page, _ in
            guard page == 1 else { return [] }
            return section.id == week.id ? (1...3).map(Self.item) : (3...5).map(Self.item)
        })
        await discover.loadIfNeeded(week)
        await discover.loadIfNeeded(rated)
        XCTAssertEqual(discover.shownItems.map(\.id), ["1", "2", "3", "4", "5"], "the home, each card once")
        discover.openSection = rated
        XCTAssertEqual(discover.shownItems.map(\.id), ["3", "4", "5"], "See More")

        let model = try workshop()
        model.selectAll(discover.shownItems)
        XCTAssertEqual(model.selectedItemIds, ["3", "4", "5"])
        model.selectItem(Self.item(5), in: discover.shownItems, kind: .toggle)
        XCTAssertEqual(model.selectedItemIds, ["3", "4"])
    }

    private func workshop() throws -> WorkshopViewModel {
        let root = FileManager.default.temporaryDirectory.appending(path: "owe-click-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) } // cleanup of a temp folder; nothing to report
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { root }),
                                       storageDirectory: { root }, previewCacheRoot: root,
                                       presentPreview: { _ in }, restoresSession: false)
        return WorkshopViewModel(steamCmd: steamCmd, searchPage: { _, _, _, _, _ in [] })
    }

    private static func item(_ number: Int) -> WorkshopItem {
        WorkshopItem(id: "\(number)", title: "Item \(number)", previewURL: nil, tags: ["Wallpaper", "Scene", "Everyone"],
                     subscriptions: 0, fileSize: 0, creatorAppId: nil, creatorId: "author", description: nil,
                     votesUp: 0, votesDown: 0)
    }
}
