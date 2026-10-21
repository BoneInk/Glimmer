import XCTest
@testable import OpenWallpaperEngine

/// The Discover tab: WE's lists as QueryFiles requests, and the paging that scrolls them on.
@MainActor
final class WorkshopDiscoverTests: XCTestCase {
    private func section(_ id: String) throws -> WorkshopDiscoverSection {
        try XCTUnwrap(WorkshopDiscover.home.first { $0.id == id })
    }

    private func values(_ items: [URLQueryItem], prefix: String) -> [String] {
        items.filter { $0.name.hasPrefix(prefix) }.compactMap(\.value)
    }

    private func value(_ items: [URLQueryItem], _ name: String) -> String? {
        items.first { $0.name == name }?.value
    }

    private func fixtureItems() throws -> [WorkshopItem] {
        try WorkshopAPIService.parseItems(from: Data(contentsOf: Fixtures.url("Workshop/api/query-files.json")))
    }

    func testTheHomeHasWEsListsAndTheTrendingOnes() {
        let ids = WorkshopDiscover.home.map(\.id)
        for id in ["popular-now", "popular-week", "recent-approved", "top-rated", "popular-approved", "popular-audio"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertEqual(Set(ids).count, ids.count, "section ids are unique")
        XCTAssertEqual(WorkshopDiscover.home.filter { $0.id.hasPrefix("genre-") }.count, WorkshopDiscover.genreTags.count)
    }

    func testTrendingListsAskForSteamsTrendOverWEsDays() throws {
        let week = WorkshopDiscover.queryItems(for: try section("popular-week"), page: 2, perPage: 30)
        XCTAssertEqual(value(week, "query_type"), "3")
        XCTAssertEqual(value(week, "days"), "7")
        XCTAssertEqual(value(week, "page"), "2")
        XCTAssertEqual(value(week, "numperpage"), "30")
        XCTAssertEqual(value(week, "appid"), "431960")
        XCTAssertTrue(values(week, prefix: "requiredtags[").isEmpty)

        let month = WorkshopDiscover.queryItems(for: try section("popular-now"), page: 1, perPage: 30)
        XCTAssertEqual(value(month, "days"), "30")
        XCTAssertEqual(value(WorkshopDiscover.queryItems(for: try section("popular-approved"), page: 1, perPage: 30),
                             "days"), "365")
    }

    func testTopRatedAndNewUseVotesAndPublicationDate() throws {
        let top = WorkshopDiscover.queryItems(for: try section("top-rated"), page: 1, perPage: 30)
        XCTAssertEqual(value(top, "query_type"), "0")
        XCTAssertNil(value(top, "days"))
        let recent = WorkshopDiscover.queryItems(for: try section("recent-approved"), page: 1, perPage: 30)
        XCTAssertEqual(value(recent, "query_type"), "1")
    }

    func testEveryListIsWallpapersForEveryoneAsInWE() throws {
        for section in WorkshopDiscover.home {
            let excluded = values(WorkshopDiscover.queryItems(for: section, page: 1, perPage: 30), prefix: "excludedtags[")
            XCTAssertTrue(excluded.contains("Preset"), section.id)
            XCTAssertTrue(excluded.contains("Questionable"), section.id)
            XCTAssertTrue(excluded.contains("Mature"), section.id)
            XCTAssertFalse(excluded.contains("Everyone"), section.id)
        }
    }

    func testApprovedListsRequireTheTagAndLeavePortraitOut() throws {
        let items = WorkshopDiscover.queryItems(for: try section("popular-now"), page: 1, perPage: 30)
        XCTAssertEqual(values(items, prefix: "requiredtags["), ["Approved"])
        XCTAssertEqual(value(items, "match_all_tags"), "true")
        XCTAssertTrue(Set(values(items, prefix: "excludedtags[")).isSuperset(of: WorkshopDiscover.portraitTags))
    }

    func testASecondTagIsCheckedOnTheResults() throws {
        let mmd = try section("genre-MMD+Anime")
        XCTAssertEqual(mmd.query.requiredTags, ["MMD"])
        XCTAssertEqual(mmd.query.clientRequiredTags, ["Anime"])
        let page = try fixtureItems()
        XCTAssertTrue(WorkshopDiscover.shownItems(page, of: mmd, after: [], hidden: { _ in false }).isEmpty)
    }

    func testShownItemsDropHiddenAndAlreadyShownOnes() throws {
        let page = try fixtureItems()
        let week = try section("popular-week")
        let shown = WorkshopDiscover.shownItems(page, of: week, after: [page[0]], hidden: { $0.id == "3100000003" })
        XCTAssertEqual(shown.map(\.id), ["3100000002"])
    }

    func testRowsLoadPageByPageUntilTheLastOne() async throws {
        let all = try fixtureItems()
        var requested: [Int] = []
        let model = WorkshopDiscoverViewModel(sections: [try section("popular-week")], fetch: { _, page, perPage in
            requested.append(page)
            XCTAssertEqual(perPage, WorkshopDiscoverViewModel.pageSize)
            // A full first page, then a short last one.
            return page == 1 ? Array(repeating: all, count: 10).flatMap { $0 }.enumerated().map { index, item in
                WorkshopItem(id: "\(4_000_000_000 + index)", title: item.title, previewURL: nil, tags: item.tags,
                             subscriptions: 0, fileSize: 0, creatorAppId: nil, creatorId: nil, description: nil,
                             votesUp: 0, votesDown: 0)
            } : [all[2]]
        })
        let week = model.sections[0]
        await model.loadIfNeeded(week)
        XCTAssertEqual(model.row(week).items.count, 30)
        XCTAssertFalse(model.row(week).reachedEnd)
        await model.loadIfNeeded(week)
        XCTAssertEqual(requested, [1], "a loaded list isn't loaded again")
        await model.loadMore(week)
        XCTAssertEqual(model.row(week).items.count, 31)
        XCTAssertTrue(model.row(week).reachedEnd)
        await model.loadMore(week)
        XCTAssertEqual(requested, [1, 2], "nothing is read past the last page")
    }

    func testAMissingAPIKeyAsksForOne() async throws {
        let model = WorkshopDiscoverViewModel(sections: [try section("top-rated")], fetch: { _, _, _ in
            throw WorkshopAPIError.noAPIKey
        })
        await model.loadIfNeeded(model.sections[0])
        XCTAssertTrue(model.needsAPIKey)
        XCTAssertNotNil(model.row(model.sections[0]).error)
        model.reload()
        XCTAssertFalse(model.needsAPIKey)
        XCTAssertEqual(model.row(model.sections[0]), WorkshopDiscoverViewModel.Row())
    }

    func testAnEmptyListLeavesTheHome() async throws {
        let model = WorkshopDiscoverViewModel(sections: [try section("top-rated"), try section("popular-week")],
                                              fetch: { section, _, _ in
            section.id == "top-rated" ? [] : try self.fixtureItems()
        })
        for section in model.sections { await model.loadIfNeeded(section) }
        XCTAssertEqual(model.visibleSections.map(\.id), ["popular-week"])
    }
}
