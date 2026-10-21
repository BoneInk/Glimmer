import XCTest
@testable import OpenWallpaperEngine

/// Blocking a Workshop wallpaper or its author hides it from the Workshop and Discover results,
/// locally; Settings lists what was blocked to unblock it.
@MainActor
final class WorkshopBlockListTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUpWithError() throws {
        suiteName = "owe-workshop-block-list-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appending(path: "owe-workshop-block-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try FileManager.default.removeItem(at: root)
    }

    private static func item(_ id: String, author: String) -> WorkshopItem {
        WorkshopItem(id: id, title: "Item \(id)", previewURL: nil, tags: ["Wallpaper", "Scene", "Everyone"],
                     subscriptions: 0, fileSize: 0, creatorAppId: nil, creatorId: author, description: nil,
                     votesUp: 0, votesDown: 0)
    }

    func testBlocksItemsAndAuthorsAndKeepsThem() {
        let list = WorkshopBlockList(defaults: defaults)
        XCTAssertTrue(list.isEmpty)
        list.block(Self.item("1", author: "a"))
        list.blockAuthor("b", name: "Bea")
        XCTAssertTrue(list.isBlocked(Self.item("1", author: "x")))
        XCTAssertTrue(list.isBlocked(Self.item("2", author: "b")), "an author's items are blocked with them")
        XCTAssertFalse(list.isBlocked(Self.item("3", author: "c")))

        let reopened = WorkshopBlockList(defaults: defaults)
        XCTAssertEqual(reopened.items, [.init(id: "1", name: "Item 1")])
        XCTAssertEqual(reopened.authors, [.init(id: "b", name: "Bea")])

        reopened.unblockItem("1")
        reopened.unblockAuthor("b")
        XCTAssertTrue(reopened.isEmpty)
        XCTAssertTrue(WorkshopBlockList(defaults: defaults).isEmpty)
    }

    func testBlockingTwiceKeepsOneEntry() {
        let list = WorkshopBlockList(defaults: defaults)
        list.block(Self.item("1", author: "a"))
        list.block(Self.item("1", author: "a"))
        list.blockAuthor("a", name: "A")
        list.blockAuthor("a", name: "A")
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.authors.count, 1)
    }

    func testTheWorkshopBrowserLeavesBlockedItemsOut() async throws {
        let catalogue = (0..<60).map { Self.item("\($0)", author: $0 % 2 == 0 ? "even" : "odd") }
        let list = WorkshopBlockList(defaults: defaults)
        list.blockAuthor("odd", name: "Odd")
        list.block(catalogue[0])
        let root = root!
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { root }),
                                       storageDirectory: { root }, previewCacheRoot: root,
                                       presentPreview: { _ in }, restoresSession: false)
        let model = WorkshopViewModel(steamCmd: steamCmd, blockList: list, searchPage: { _, _, _, page, perPage in
            let start = (page - 1) * perPage
            guard start < catalogue.count else { return [] }
            return Array(catalogue[start..<min(start + perPage, catalogue.count)])
        })
        await model.search()
        XCTAssertFalse(model.items.isEmpty)
        XCTAssertFalse(model.items.contains { $0.creatorId == "odd" || $0.id == "0" })
        XCTAssertEqual(model.items.first?.id, "2")
    }

    func testDiscoverLeavesBlockedItemsOutAndDropsNewlyBlockedOnes() async throws {
        let page = try WorkshopAPIService.parseItems(from: Data(contentsOf: Fixtures.url("Workshop/api/query-files.json")))
        let list = WorkshopBlockList(defaults: defaults)
        list.block(page[0])
        let section = try XCTUnwrap(WorkshopDiscover.home.first { $0.id == "popular-week" })
        let model = WorkshopDiscoverViewModel(sections: [section], blockList: list, fetch: { _, _, _ in page })
        await model.loadIfNeeded(section)
        XCTAssertEqual(model.row(section).items.map(\.id), ["3100000002", "3100000003"])

        list.blockAuthor("76561190000000003", name: "Someone")
        // The list drops it on the next main-queue turn.
        for _ in 0..<500 where model.row(section).items.count != 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.row(section).items.map(\.id), ["3100000002"])
    }
}
