import XCTest
@testable import OpenWallpaperEngine

/// The Workshop filter's QueryFiles parameters, the response's tags and the checks made on the
/// results. No network: the requests are only built, and responses are recorded fixtures.
final class WorkshopFilterTests: XCTestCase {
    // MARK: Query planning

    func testDefaultFilterExcludesTheUncheckedRatingsLikeWE() {
        let query = WorkshopQuery(WorkshopFilter())
        XCTAssertEqual(query.excludedTags, ["Questionable", "Mature"])
        XCTAssertEqual(query.requiredTags, [])
        XCTAssertTrue(query.clientShowOnly.isEmpty)
    }

    func testAGroupWithNothingOrEverythingCheckedDoesNotFilter() {
        var filter = WorkshopFilter()
        filter.ratings = []
        filter.types = Set(WorkshopTags.types)
        filter.resolutions = []
        XCTAssertEqual(WorkshopQuery(filter).excludedTags, [])
    }

    func testOrGroupsExcludeTheirUncheckedTagsAndCombine() {
        var filter = WorkshopFilter()
        filter.ratings = ["Everyone", "Questionable"]
        filter.types = ["Scene", "Video"]
        filter.resolutions = ["3840 x 2160"]
        let excluded = WorkshopQuery(filter).excludedTags
        XCTAssertEqual(Array(excluded.prefix(3)), ["Mature", "Web", "Application"])
        XCTAssertEqual(excluded.count, 3 + WEResolutionTags.all.count - 1)
        XCTAssertFalse(excluded.contains("3840 x 2160"))
        XCTAssertTrue(excluded.contains("Ultrawide 3440 x 1440"))
    }

    /// Steam's Web API returns next to nothing for two or more requiredtags with
    /// match_all_tags=true (Anime + Girls: 4 of 649,855 Anime items), so AND sends one tag and
    /// checks the others on the results.
    func testAndedGenresSendOneTagAndCheckTheRest() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime", "Abstract", "Girls"]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Abstract"], "WE's order")
        XCTAssertTrue(query.matchAllTags)
        XCTAssertEqual(query.clientRequiredTags, ["Anime", "Girls"])
    }

    func testNeverSendsSeveralTagsWithMatchAll() {
        let genreSets: [Set<String>] = [[], ["Anime"], ["Anime", "Girls"], ["Anime", "Girls", "Music"]]
        let showOnlySets: [Set<WorkshopShowOnly>] = [[], [.approved], [.favourites], [.mobileCompatible],
                                                     [.approved, .customizable]]
        for genres in genreSets {
            for match in [WorkshopTagMatch.all, .any] {
                for showOnly in showOnlySets {
                    var filter = WorkshopFilter()
                    filter.genres = genres
                    filter.genreMatch = match
                    filter.showOnly = showOnly
                    let query = WorkshopQuery(filter)
                    if query.matchAllTags {
                        XCTAssertLessThanOrEqual(query.requiredTags.count, 1, "\(genres) \(match) \(showOnly)")
                    }
                    let items = WorkshopAPIService.queryItems(text: "", filter: query, sortOrder: .default,
                                                              page: 1, perPage: 50)
                    let required = items.filter { $0.name.hasPrefix("requiredtags[") }.map(\.name)
                    XCTAssertEqual(required, required.indices.map { "requiredtags[\($0)]" }, "0-based, contiguous")
                }
            }
        }
    }

    func testGenresAreRequiredAllOrAny() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime", "Abstract"]
        var query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Abstract"])
        XCTAssertEqual(query.clientRequiredTags, ["Anime"])
        XCTAssertTrue(query.matchAllTags)

        filter.genreMatch = .any
        query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Abstract", "Anime"])
        XCTAssertFalse(query.matchAllTags)
        XCTAssertEqual(query.clientRequiredTags, [])
    }

    func testOneShowOnlyTagJoinsTheRequiredTagsWhenGenresAreAND() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime", "Girls"]
        filter.showOnly = [.approved]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Anime"])
        XCTAssertEqual(query.clientRequiredTags, ["Girls", "Approved"])
        XCTAssertTrue(query.matchAllTags)
        XCTAssertTrue(query.clientShowOnly.isEmpty)

        filter.genres = []
        XCTAssertEqual(WorkshopQuery(filter).requiredTags, ["Approved"])
        XCTAssertEqual(WorkshopQuery(filter).clientRequiredTags, [])
    }

    func testOneShowOnlyTagWithOrGenresIsCheckedOnTheResults() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime", "Girls"]
        filter.genreMatch = .any
        filter.showOnly = [.customizable]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Anime", "Girls"])
        XCTAssertFalse(query.matchAllTags)
        XCTAssertEqual(query.clientShowOnly, [.customizable])
    }

    func testOneOrGenreBehavesAsAND() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime"]
        filter.genreMatch = .any
        filter.showOnly = [.audioResponsive]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, ["Anime"])
        XCTAssertEqual(query.clientRequiredTags, ["Audio responsive"])
        XCTAssertTrue(query.matchAllTags)
    }

    func testSeveralShowOnlyOptionsAreCheckedOnTheResults() {
        var filter = WorkshopFilter()
        filter.showOnly = [.approved, .audioResponsive]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.requiredTags, [])
        XCTAssertEqual(query.clientShowOnly, [.approved, .audioResponsive])
    }

    func testMobileAloneExcludesWebAndApplicationAndChecksTheEULATag() {
        var filter = WorkshopFilter()
        filter.showOnly = [.mobileCompatible]
        filter.types = ["Scene", "Web"]
        let query = WorkshopQuery(filter)
        XCTAssertEqual(query.excludedTags, ["Questionable", "Mature", "Video", "Application", "Web"])
        XCTAssertEqual(query.clientShowOnly, [.mobileCompatible])
    }

    func testFavouritesAreCheckedOnTheResults() {
        var filter = WorkshopFilter()
        filter.showOnly = [.favourites]
        XCTAssertEqual(WorkshopQuery(filter).clientShowOnly, [.favourites])
    }

    func testHideAnimeExcludesWEsGenresButTheTickedOnes() {
        var filter = WorkshopFilter()
        filter.hidesAnime = true
        XCTAssertEqual(WorkshopQuery(filter).excludedTags, ["Questionable", "Mature", "Anime", "MMD", "Girls", "Guys", "Music"])
        filter.genres = ["Girls"]
        let ticked = WorkshopQuery(filter)
        XCTAssertFalse(ticked.excludedTags.contains("Girls"))
        XCTAssertEqual(ticked.requiredTags, ["Girls"])
        XCTAssertNotEqual(filter.cacheKey, WorkshopFilter().cacheKey)
    }

    func testExactPhraseQuotesTheSearchAsWE() {
        XCTAssertFalse(WorkshopSearchText.offersExactPhrase("rain"))
        XCTAssertFalse(WorkshopSearchText.offersExactPhrase(" rain "))
        XCTAssertTrue(WorkshopSearchText.offersExactPhrase("rainy night"))
        XCTAssertEqual(WorkshopSearchText.steamText("rainy night", exactPhrase: false), "rainy night")
        XCTAssertEqual(WorkshopSearchText.steamText("rainy night", exactPhrase: true), "\"rainy night\"")
        XCTAssertEqual(WorkshopSearchText.steamText("\"rainy\" night", exactPhrase: true), "\"rainy\" night")
        XCTAssertEqual(WorkshopSearchText.steamText("", exactPhrase: true), "")
    }

    // MARK: Request parameters

    func testQueryFilesParameters() {
        let query = WorkshopQuery(requiredTags: ["Anime", "Girls"], matchAllTags: false,
                                  excludedTags: ["Mature", "Questionable"])
        let items = WorkshopAPIService.queryItems(text: "rain", filter: query, sortOrder: .mostRecent,
                                                  page: 3, perPage: 50)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("match_all_tags"), "false")
        XCTAssertEqual(value("requiredtags[0]"), "Anime")
        XCTAssertEqual(value("requiredtags[1]"), "Girls")
        XCTAssertEqual(value("excludedtags[0]"), "Mature")
        XCTAssertEqual(value("excludedtags[1]"), "Questionable")
        XCTAssertEqual(value("return_tags"), "true")
        XCTAssertEqual(value("return_kv_tags"), "true")
        XCTAssertEqual(value("search_text"), "rain")
        XCTAssertEqual(value("query_type"), "12", "text search")
        XCTAssertEqual(value("page"), "3")
        XCTAssertEqual(value("numperpage"), "50")
        XCTAssertNil(value("requiredtags[2]"))

        let allTags = WorkshopAPIService.queryItems(text: "", filter: WorkshopQuery(requiredTags: ["Anime"]),
                                                    sortOrder: .mostRecent, page: 1, perPage: 20)
        XCTAssertEqual(allTags.first { $0.name == "match_all_tags" }?.value, "true")
        XCTAssertEqual(allTags.first { $0.name == "query_type" }?.value, "1")
        XCTAssertNil(allTags.first { $0.name == "search_text" })
    }

    func testSortsAreWEsListAsQueryFilesQueryTypes() {
        XCTAssertEqual(WorkshopSortOrder.allCases.map(\.rawValue),
                       ["top_rated", "trend_year", "trend_month", "trend_week", "trend_today", "most_recent",
                        "most_up_votes", "subscriptions"])
        XCTAssertEqual(WorkshopSortOrder.default, .trendYear)
        func parameters(_ sort: WorkshopSortOrder, text: String = "") -> (type: String?, days: String?) {
            let items = WorkshopAPIService.queryItems(text: text, filter: WorkshopQuery(), sortOrder: sort,
                                                      page: 1, perPage: 20)
            return (items.first { $0.name == "query_type" }?.value, items.first { $0.name == "days" }?.value)
        }
        let expected: [WorkshopSortOrder: (String, String?)] = [
            .topRated: ("0", nil), .trendYear: ("3", "365"), .trendMonth: ("3", "30"), .trendWeek: ("3", "7"),
            .trendToday: ("3", "1"), .mostRecent: ("1", nil), .mostUpVotes: ("11", nil), .subscriptions: ("9", nil),
        ]
        for (sort, value) in expected {
            let (type, days) = value
            let sent = parameters(sort)
            XCTAssertEqual(sent.type, type, "\(sort)")
            XCTAssertEqual(sent.days, days, "\(sort)")
        }
        // A text search is ranked by relevance, without a trend window.
        let search = parameters(.trendWeek, text: "rain")
        XCTAssertEqual(search.type, "12")
        XCTAssertNil(search.days)
    }

    // MARK: Response parsing

    private let recordedResponse = """
    {"response":{"total":2,"publishedfiledetails":[
      {"publishedfileid":"111","title":"Rain","preview_url":"https://example.invalid/p.jpg",
       "tags":[{"tag":"Scene","display_name":"Scene"},{"tag":"Anime","display_name":"Anime"},
               {"tag":"3840 x 2160","display_name":"3840 x 2160"},{"tag":"Everyone","display_name":"Everyone"}],
       "kvtags":[{"key":"app_workshop_eula_version","value":"3"}],
       "subscriptions":12,"file_size":2048,"creator":"7","votes_up":3,"votes_down":1},
      {"publishedfileid":"222","title":"Site","tags":[{"tag":"Web"},{"tag":"Approved"}]}
    ]}}
    """

    func testParsesTagsAndKeyValueTags() throws {
        let items = try WorkshopAPIService.parseItems(from: Data(recordedResponse.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].tags, ["3840 x 2160", "Anime", "Everyone", "Scene"])
        XCTAssertEqual(items[0].kvTags, ["app_workshop_eula_version": "3"])
        XCTAssertEqual(items[1].tags, ["Approved", "Web"])
        XCTAssertNil(items[1].kvTags)
    }

    func testItemsStoredBeforeKeyValueTagsStillDecode() throws {
        let stored = #"{"id":"1","title":"t","tags":["Scene"],"subscriptions":0,"fileSize":0,"votesUp":0,"votesDown":0}"#
        let item = try JSONDecoder().decode(WorkshopItem.self, from: Data(stored.utf8))
        XCTAssertEqual(item.tags, ["Scene"])
        XCTAssertNil(item.kvTags)
    }

    // MARK: Checks on the results

    private func item(_ id: String, tags: [String], kv: [String: String]? = nil) -> WorkshopItem {
        WorkshopItem(id: id, title: id, previewURL: nil, tags: tags, subscriptions: 0, fileSize: 0,
                     creatorAppId: nil, creatorId: nil, description: nil, votesUp: 0, votesDown: 0, kvTags: kv)
    }

    func testResultChecksAreOrAcrossTheCheckedOptions() {
        let query = WorkshopQuery(clientShowOnly: [.approved, .favourites])
        let approved = item("a", tags: ["Scene", "approved"])
        let favourite = item("f", tags: ["Scene"])
        let neither = item("n", tags: ["Scene", "Customizable"])
        let isFavorite: (WorkshopItem) -> Bool = { $0.id == "f" }
        XCTAssertTrue(query.matches(approved, isFavorite: isFavorite), "tags match regardless of case")
        XCTAssertTrue(query.matches(favourite, isFavorite: isFavorite))
        XCTAssertFalse(query.matches(neither, isFavorite: isFavorite))
        XCTAssertTrue(WorkshopQuery().matches(neither, isFavorite: isFavorite), "nothing to check")
    }

    func testClientRequiredTagsMustAllBePresent() {
        let query = WorkshopQuery(requiredTags: ["Anime"], clientRequiredTags: ["Girls", "Music"])
        let never: (WorkshopItem) -> Bool = { _ in false }
        XCTAssertTrue(query.matches(item("y", tags: ["Anime", "girls", "Music"]), isFavorite: never))
        XCTAssertFalse(query.matches(item("n", tags: ["Anime", "Girls"]), isFavorite: never))
    }

    func testMobileNeedsTheEULATagAndNoWebOrApplication() {
        let query = WorkshopQuery(clientShowOnly: [.mobileCompatible])
        let never: (WorkshopItem) -> Bool = { _ in false }
        XCTAssertTrue(query.matches(item("s", tags: ["Scene"], kv: ["app_workshop_eula_version": "3"]), isFavorite: never))
        XCTAssertFalse(query.matches(item("w", tags: ["Web"], kv: ["app_workshop_eula_version": "3"]), isFavorite: never))
        XCTAssertFalse(query.matches(item("o", tags: ["Scene"], kv: ["app_workshop_eula_version": "2"]), isFavorite: never))
        XCTAssertFalse(query.matches(item("u", tags: ["Scene"]), isFavorite: never))
    }

    // MARK: Tag spellings

    func testTagsAreSpelledAsWorkshopItemsCarryThem() {
        XCTAssertTrue(WorkshopTags.genres.contains("Pixel art"))
        XCTAssertFalse(WorkshopTags.genres.contains("Pixel Art"))
        XCTAssertTrue(WEResolutionTags.all.contains("Ultrawide 3440 x 1440"))
        XCTAssertTrue(WEResolutionTags.all.contains("Portrait 1440 x 2560"))
        XCTAssertEqual(Set(WEResolutionTags.all).count, WEResolutionTags.all.count)
    }

    func testInstalledResolutionOptionsAreTheSameTags() {
        let installed = FRWidescreenResolution.optionKeys + FRUltraWidescreenResolution.optionKeys
            + FRDualscreenResolution.optionKeys + FRTriplescreenResolution.optionKeys
            + FRPortraitScreenResolution.optionKeys + FRMiscResolution.optionKeys
        XCTAssertEqual(Set(installed), Set(WEResolutionTags.all))
    }
}
