import XCTest
@testable import OpenWallpaperEngine

/// The Workshop tab's filters end to end through `WorkshopViewModel`: ticking genres narrows (AND)
/// or widens (OR) what the grid shows, the other groups and Show Only apply, pages continue where
/// the previous one ended, and a search overtaken by a newer one never shows its results. Steam is
/// a fake that answers QueryFiles over a fixture catalogue the way Steam does (required tags all
/// or any, excluded tags, pages); nothing touches the network or the keychain.
@MainActor
final class WorkshopFilterPagingTests: XCTestCase {
    /// QueryFiles over `catalogue`, with a per-request delay to make searches overlap.
    private final class FakeSteam {
        let catalogue: [WorkshopItem]
        var requests: [WorkshopQuery] = []
        /// The `search_text` of each request.
        var texts: [String] = []
        /// Delay for the n-th request (0-based); none by default.
        var delay: (Int) -> Duration = { _ in .zero }

        init(catalogue: [WorkshopItem]) { self.catalogue = catalogue }

        func search(_ text: String, _ query: WorkshopQuery, _ sort: WorkshopSortOrder,
                    _ page: Int, _ perPage: Int) async throws -> [WorkshopItem] {
            let index = requests.count
            requests.append(query)
            texts.append(text)
            let wait = delay(index)
            if wait > .zero { try await Task.sleep(for: wait) }
            let matching = catalogue.filter { item in
                let tags = Set(item.tags)
                if query.excludedTags.contains(where: tags.contains) { return false }
                guard !query.requiredTags.isEmpty else { return true }
                return query.matchAllTags ? query.requiredTags.allSatisfy(tags.contains)
                                          : query.requiredTags.contains(where: tags.contains)
            }
            let start = (page - 1) * perPage
            guard start < matching.count else { return [] }
            return Array(matching[start..<min(start + perPage, matching.count)])
        }
    }

    private var root: URL!
    /// The view model's own defaults, so Hide Anime never reaches another test.
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var steam: FakeSteam!
    private var viewModel: WorkshopViewModel!

    /// 600 items; item i has Anime when i is even, Girls when divisible by 3, Music by 5, is a
    /// Video when divisible by 4 (else a Scene), Mature when divisible by 7 (else Everyone), and
    /// Approved when divisible by 11.
    private static let catalogue: [WorkshopItem] = (0..<600).map { i in
        var tags: [String] = []
        if i % 2 == 0 { tags.append("Anime") }
        if i % 3 == 0 { tags.append("Girls") }
        if i % 5 == 0 { tags.append("Music") }
        tags.append(i % 4 == 0 ? "Video" : "Scene")
        tags.append(i % 7 == 0 ? "Mature" : "Everyone")
        if i % 11 == 0 { tags.append("Approved") }
        return WorkshopItem(id: "\(i)", title: "Item \(i)", previewURL: nil, tags: tags, subscriptions: 0,
                            fileSize: 0, creatorAppId: nil, creatorId: nil, description: nil,
                            votesUp: 0, votesDown: 0)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "owe-workshop-paging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = root!
        let steamCmd = SteamCmdService(dependencyIndex: WorkshopDependencyIndex(libraryDirectory: { root }),
                                       storageDirectory: { root }, previewCacheRoot: root,
                                       presentPreview: { _ in }, restoresSession: false)
        let steam = FakeSteam(catalogue: Self.catalogue)
        self.steam = steam
        suiteName = "WorkshopFilterPagingTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        viewModel = WorkshopViewModel(steamCmd: steamCmd, searchPage: steam.search, defaults: defaults)
    }

    override func tearDownWithError() throws {
        viewModel = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try FileManager.default.removeItem(at: root)
    }

    /// Waits for the newest search to finish (the view model runs it in its own task).
    private func settle(file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            try await Task.sleep(for: .milliseconds(10))
            if !viewModel.isLoading { return }
        }
        XCTFail("the search never finished", file: file, line: line)
    }

    private func tick(_ genre: String) async throws {
        viewModel.updateFilter { $0.genres.insert(genre) }
        try await settle()
    }

    /// What Steam plus the client-side checks should show: every catalogue item passing `keep`,
    /// in catalogue order, after the default rating filter (Everyone only).
    private func expected(_ keep: (Set<String>) -> Bool) -> [String] {
        Self.catalogue.filter { item in
            let tags = Set(item.tags)
            return !tags.contains("Mature") && !tags.contains("Questionable") && keep(tags)
        }.map(\.id)
    }

    private var shownIds: [String] { viewModel.items.map(\.id) }

    // MARK: Genres

    func testEachTickedGenreNarrowsTheResultsWhenAND() async throws {
        let perPage = viewModel.itemsPerPage
        try await tick("Anime")
        XCTAssertEqual(shownIds, Array(expected { $0.contains("Anime") }.prefix(perPage)))

        try await tick("Girls")
        XCTAssertEqual(shownIds, Array(expected { $0.isSuperset(of: ["Anime", "Girls"]) }.prefix(perPage)),
                       "the second genre narrows")

        try await tick("Music")
        XCTAssertEqual(shownIds, Array(expected { $0.isSuperset(of: ["Anime", "Girls", "Music"]) }.prefix(perPage)),
                       "the third genre narrows")
        XCTAssertTrue(viewModel.items.allSatisfy { Set($0.tags).isSuperset(of: ["Anime", "Girls", "Music"]) })
        XCTAssertTrue(steam.requests.allSatisfy { !$0.matchAllTags || $0.requiredTags.count <= 1 },
                      "Steam never gets two AND-ed tags")
    }

    func testEachTickedGenreWidensTheResultsWhenOR() async throws {
        viewModel.updateFilter { $0.genreMatch = .any }
        try await settle()
        try await tick("Music")
        let musicOnly = expected { $0.contains("Music") }
        XCTAssertEqual(shownIds, Array(musicOnly.prefix(viewModel.itemsPerPage)))

        try await tick("Girls")
        let musicOrGirls = expected { $0.contains("Music") || $0.contains("Girls") }
        XCTAssertGreaterThan(musicOrGirls.count, musicOnly.count)
        XCTAssertEqual(shownIds, Array(musicOrGirls.prefix(viewModel.itemsPerPage)), "the second genre widens")

        try await tick("Anime")
        XCTAssertEqual(shownIds, Array(expected { !$0.isDisjoint(with: ["Music", "Girls", "Anime"]) }
            .prefix(viewModel.itemsPerPage)), "the third genre widens")
    }

    func testSwitchingTheGenreModeReFilters() async throws {
        try await tick("Anime")
        try await tick("Music")
        let and = shownIds
        viewModel.updateFilter { $0.genreMatch = .any }
        try await settle()
        XCTAssertNotEqual(shownIds, and)
        XCTAssertEqual(shownIds, Array(expected { $0.contains("Anime") || $0.contains("Music") }
            .prefix(viewModel.itemsPerPage)))
    }

    // MARK: Other groups

    func testTypeRatingAndShowOnlyNarrowTogetherWithGenres() async throws {
        viewModel.updateFilter { $0.types = ["Video"] }
        try await settle()
        XCTAssertEqual(shownIds, Array(expected { $0.contains("Video") }.prefix(viewModel.itemsPerPage)))

        try await tick("Anime")
        try await tick("Girls")
        viewModel.updateFilter { $0.showOnly = [.approved] }
        try await settle()
        XCTAssertEqual(shownIds, expected { $0.isSuperset(of: ["Video", "Anime", "Girls", "Approved"]) }
            .prefix(viewModel.itemsPerPage).map { $0 })

        viewModel.updateFilter { $0.ratings = ["Mature"] }
        try await settle()
        let mature = Self.catalogue.filter {
            Set($0.tags).isSuperset(of: ["Mature", "Video", "Anime", "Girls", "Approved"])
        }.map(\.id)
        XCTAssertEqual(shownIds, Array(mature.prefix(viewModel.itemsPerPage)))
    }

    // MARK: Paging

    func testPagesContinueWithoutGapsOrRepeatsAndReachAShortLastPage() async throws {
        try await tick("Anime")
        try await tick("Girls")
        let all = expected { $0.isSuperset(of: ["Anime", "Girls"]) }
        XCTAssertNotEqual(all.count % viewModel.itemsPerPage, 0, "the fixture ends on a short page")

        var seen: [String] = shownIds
        while viewModel.hasNextPage {
            viewModel.currentPage += 1
            await viewModel.search()
            XCTAssertFalse(viewModel.items.isEmpty, "page \(viewModel.currentPage)")
            seen += shownIds
        }
        XCTAssertEqual(seen, all, "every matching item once, in order, the short last page included")
    }

    // MARK: Overlapping searches

    func testAnOvertakenSearchDoesNotReplaceTheNewestResults() async throws {
        // The first request (for "Anime") is slow; ticking "Girls" meanwhile searches again.
        steam.delay = { $0 == 0 ? .milliseconds(400) : .zero }
        viewModel.updateFilter { $0.genres.insert("Anime") }
        try await Task.sleep(for: .milliseconds(20))
        viewModel.updateFilter { $0.genres.insert("Girls") }
        try await settle()
        let both = Array(expected { $0.isSuperset(of: ["Anime", "Girls"]) }.prefix(viewModel.itemsPerPage))
        XCTAssertEqual(shownIds, both)

        // Let the overtaken search finish: the grid and the page cache keep the newest results.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(shownIds, both)
        viewModel.currentPage = 2
        await viewModel.search()
        XCTAssertEqual(shownIds, Array(expected { $0.isSuperset(of: ["Anime", "Girls"]) }
            .dropFirst(viewModel.itemsPerPage).prefix(viewModel.itemsPerPage)))
    }

    func testChangingTheFilterClearsTheStaleResultsWhileSearching() async throws {
        try await tick("Anime")
        XCTAssertFalse(viewModel.items.isEmpty)
        steam.delay = { _ in .milliseconds(200) }
        viewModel.updateFilter { $0.genres.insert("Girls") }
        XCTAssertTrue(viewModel.items.isEmpty, "the Anime-only results aren't shown as if they matched")
        try await settle()
        XCTAssertTrue(viewModel.items.allSatisfy { Set($0.tags).isSuperset(of: ["Anime", "Girls"]) })
    }

    // MARK: Author results

    func testAnAuthorsItemsAreCheckedAgainstTheWholeFilter() {
        var filter = WorkshopFilter()
        filter.genres = ["Anime", "Girls"]
        filter.types = ["Scene"]
        let query = WorkshopQuery(filter)
        let shown = Self.catalogue.filter { query.matchesAllTags($0, isFavorite: { _ in false }) }.map(\.id)
        XCTAssertEqual(shown, expected { $0.isSuperset(of: ["Anime", "Girls", "Scene"]) })

        filter.genreMatch = .any
        let any = WorkshopQuery(filter)
        let shownAny = Self.catalogue.filter { any.matchesAllTags($0, isFavorite: { _ in false }) }.map(\.id)
        XCTAssertEqual(shownAny, expected { $0.contains("Scene") && ($0.contains("Anime") || $0.contains("Girls")) })
    }

    // MARK: Hide Anime and Exact phrase

    func testHideAnimeLeavesOutWEsAnimeGenresUnlessOneIsTicked() async throws {
        viewModel.setHidesAnime(true)
        try await settle()
        XCTAssertEqual(shownIds, Array(expected { $0.isDisjoint(with: ["Anime", "Girls", "Music"]) }
            .prefix(viewModel.itemsPerPage)))

        try await tick("Girls")
        XCTAssertEqual(shownIds, Array(expected { $0.contains("Girls") && $0.isDisjoint(with: ["Anime", "Music"]) }
            .prefix(viewModel.itemsPerPage)), "a ticked genre shows again")

        viewModel.resetFilters()
        try await settle()
        XCTAssertTrue(viewModel.filter.hidesAnime, "Reset Filters keeps Hide Anime, as WE applies it again")
        XCTAssertTrue(viewModel.filter.genres.isEmpty)
        XCTAssertEqual(steam.requests.last?.excludedTags.filter(WorkshopTags.hiddenByHideAnime.contains),
                       WorkshopTags.hiddenByHideAnime)
    }

    func testHideAnimeIsSavedForTheNextLaunch() {
        let first = WorkshopViewModel(steamCmd: viewModel.steamCmd, searchPage: steam.search, defaults: defaults)
        XCTAssertFalse(first.filter.hidesAnime, "WE shows Anime until asked to hide it")
        first.setHidesAnime(true)
        let next = WorkshopViewModel(steamCmd: viewModel.steamCmd, searchPage: steam.search, defaults: defaults)
        XCTAssertTrue(next.filter.hidesAnime)
    }

    func testExactPhraseSendsTheSearchQuoted() async throws {
        viewModel.searchText = "rainy night"
        await viewModel.search()
        XCTAssertEqual(steam.texts.last, "rainy night")

        viewModel.setExactPhrase(true)
        try await settle()
        XCTAssertEqual(steam.texts.last, "\"rainy night\"")

        viewModel.searchText = "\"rainy\" night"
        await viewModel.search()
        XCTAssertEqual(steam.texts.last, "\"rainy\" night", "a search with a quote is sent as typed")
    }
}
