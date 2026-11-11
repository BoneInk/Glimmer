import Foundation

actor FilterSearchFixture {
    private(set) var calls: [WorkshopSearchRequest] = []
    private var shouldFail = false
    func setFailure(_ value: Bool) { shouldFail = value }
    func search(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        calls.append(request)
        if shouldFail { throw URLError(.cannotConnectToHost) }
        return WorkshopSearchPage(request: request, totalCount: 50, totalPages: 3,
                                  results: [], discoveryPath: "filter-fixture")
    }
}

@main struct WorkshopFilterTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { fatalError("FAIL: \(label)") }
        }
        func queryItems(_ request: WorkshopSearchRequest) -> [URLQueryItem] {
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)!.queryItems!
        }
        func tags(_ request: WorkshopSearchRequest) -> [String] {
            queryItems(request).filter { $0.name.hasPrefix("requiredtags[") }.compactMap(\.value)
        }
        func wait(_ coordinator: WorkshopCoordinator) async throws {
            for _ in 0..<200 {
                if !coordinator.isSearching { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            fatalError("search fixture timed out")
        }
        let empty = WorkshopSearchFilters()
        check(empty.isEmpty && empty.activeCount == 0 && empty.activeLabels.isEmpty, "empty selection")
        check(tags(WorkshopSearchRequest()) == ["Video"], "default request unchanged video scope")
        var filters = WorkshopSearchFilters(resolution: .size1920X1080, genre: .nature, ageRating: .everyone)
        check(filters.activeCount == 3 && filters.activeLabels.count == 3, "chips and count")
        let expected = ["Video", "1920 x 1080", "Nature", "Everyone"]
        let filtered = WorkshopSearchRequest(query: "山海 & Sci-Fi + #?", filters: filters)
        check(tags(filtered) == expected, "ordered contiguous required tags")
        check(queryItems(filtered).first { $0.name == "searchtext" }?.value == "山海 & Sci-Fi + #?", "multilingual and special query roundtrip")
        check(filtered.url == WorkshopSearchRequest(query: filtered.query, filters: filters).url, "deterministic URL")
        filters.resolution = .portrait2160X3840
        check(filters.activeCount == 3 && filters.requiredTags.filter { $0.contains("2160") }.count == 1, "typed replacement ensures one resolution")
        check(WorkshopResolution(rawValue: "arbitrary") == nil && WorkshopGenre(rawValue: "Video") == nil, "whitelist rejects arbitrary tags")
        check(WorkshopResolution.allCases.count == 25 && WorkshopGenre.allCases.count == 25 && WorkshopAgeRating.allCases.count == 3, "official metadata group counts")
        for resolution in WorkshopResolution.allCases {
            let request = WorkshopSearchRequest(filters: WorkshopSearchFilters(resolution: resolution))
            check(tags(request) == ["Video", resolution.rawValue], "resolution URL \(resolution.rawValue)")
        }
        for genre in WorkshopGenre.allCases {
            check(tags(WorkshopSearchRequest(filters: WorkshopSearchFilters(genre: genre))) == ["Video", genre.rawValue], "genre URL \(genre.rawValue)")
        }
        for age in WorkshopAgeRating.allCases {
            let items = queryItems(WorkshopSearchRequest(filters: WorkshopSearchFilters(ageRating: age)))
            check(items.filter { $0.name.contains("tags") }.compactMap(\.value) == ["Video", age.rawValue]
                  && !items.contains { $0.name.contains("adult") || $0.name.contains("agecheck") }, "age tag never bypasses content settings")
        }
        var multiple = WorkshopSearchFilters(resolution: .size1920X1080, genre: .nature, ageRating: .everyone)
        multiple.toggle(WorkshopResolution.size2560X1440)
        multiple.toggle(WorkshopGenre.landscape)
        multiple.toggle(WorkshopAgeRating.questionable)
        check(multiple.resolutions == [.size1920X1080, .size2560X1440] && multiple.genres == [.landscape, .nature]
              && multiple.ageRatings == [.everyone, .questionable], "all three groups retain multiple choices")
        check(multiple.activeCount == 6 && multiple.activeLabels.count == 3, "all selected values are counted with one summary per group")
        let combinations = multiple.searchBranches
        check(combinations.count == 8 && combinations.allSatisfy { $0.requiredTags.count == 3 }, "OR within groups expands to valid AND queries across groups")
        check(Set(combinations.map(\.requiredTags)).count == 8 && combinations == multiple.searchBranches, "every combination is unique and deterministic")
        multiple.toggle(WorkshopGenre.landscape)
        check(multiple.genres == [.nature] && multiple.resolutions.count == 2 && multiple.ageRatings.count == 2, "clicking a selected chip removes only that value")
        multiple.genres = []
        check(multiple.genres.isEmpty && multiple.resolutions.count == 2 && multiple.ageRatings.count == 2, "unlimited clears only its own group")
        multiple.genres = [.landscape, .nature]

        let service = WorkshopService(searchPageLoader: { request in
            let firstGenre = request.filters.genre == .landscape
            let ids: [String]
            if request.page == 1 { ids = firstGenre ? ["shared", "landscape"] : ["shared"] }
            else { ids = firstGenre ? ["landscape2"] : ["nature2"] }
            return WorkshopSearchPage(request: request, totalCount: firstGenre ? 3 : 2, totalPages: 2,
                results: ids.map { .init(publishedFileID: $0, title: $0, shortDescription: "", tags: request.filters.requiredTags + ["Video"], childCount: 0, isCollection: false) },
                discoveryPath: "overlapping-genre-fixture")
        })
        var groupedRequest = WorkshopSearchRequest(pageSize: 2)
        groupedRequest.filters.genres = [.nature, .landscape]
        let groupedFirst = try await service.search(groupedRequest)
        groupedRequest.page = 2
        let groupedSecond = try await service.search(groupedRequest)
        check(groupedFirst.results.map(\.id) == ["shared", "landscape"] && groupedSecond.results.map(\.id) == ["nature2", "landscape2"], "overlap and short server pages do not reorder or repeat logical pages")
        check(!groupedSecond.hasNextPage && groupedSecond.totalCount == 4 && groupedSecond.totalPages == 2, "a full final union page exposes the exact deduplicated count without a phantom next page")
        let repeatedSecond = try await service.search(groupedRequest)
        check(repeatedSecond == groupedSecond, "retry reuses the same stable union page")
        groupedRequest.page = 1
        let refreshedFirst = try await service.search(groupedRequest)
        check(refreshedFirst.results == groupedFirst.results, "refresh returns the same deterministic first page")
        filters = multiple
        filters.type = .web
        check(tags(WorkshopSearchRequest(filters: filters)).first == "Web", "Web filter selected before coordinator pagination and retry regression")
        var unionRequest = WorkshopSearchRequest(page: 1, pageSize: 2, filters: .init(types: [.video, .web], genre: .nature))
        let typeService = WorkshopService(searchPageLoader: { request in
            let type = request.filters.type == .video ? "Video" : "Web"
            let prefix = type == "Video" ? "v" : "w"
            let results = (1...3).map { index in
                WorkshopSearchResult(publishedFileID: "\(prefix)\(index)", title: type, shortDescription: "", tags: [type], childCount: 0, isCollection: false)
            }
            return WorkshopSearchPage(request: request, totalCount: 3, totalPages: 1, results: results, discoveryPath: "type-fixture")
        })
        let unionFirst = try await typeService.search(unionRequest)
        unionRequest.page = 2
        let unionSecond = try await typeService.search(unionRequest)
        check(unionFirst.results.map(\.id) == ["v1", "w1"] && unionSecond.results.map(\.id) == ["v2", "w2"], "multi-type pagination is stable and does not repeat the first logical page")
        unionRequest.page = 3
        let unionLast = try await typeService.search(unionRequest)
        check(unionLast.totalCount == 6 && unionLast.totalPages == 3 && !unionLast.hasNextPage && unionLast.isTotalCountExact, "multi-type union ends with exact partition pagination")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = FilterSearchFixture()
        let store = WorkshopBrowserStore(persistenceURL: root.appendingPathComponent("browser.json"))
        let account = SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("SteamCMD")))
        let coordinator = WorkshopCoordinator(account: account, browserStore: store,
                                              searchOperation: { try await fixture.search($0) }, queuePersistence: .disabled)
        coordinator.setFiltersAndSearch(filters)
        try await wait(coordinator)
        check(coordinator.lastRequest.page == 1 && coordinator.lastRequest.filters == filters, "apply commits real search")
        check(coordinator.recentSearches.isEmpty, "filter-only search creates no fake history")
        coordinator.nextPage()
        try await wait(coordinator)
        check(coordinator.lastRequest.page == 2 && coordinator.lastRequest.filters == filters, "pagination preserves exact filters")
        coordinator.filters = WorkshopSearchFilters(genre: .anime)
        await fixture.setFailure(true)
        coordinator.retrySearch()
        try await wait(coordinator)
        check(coordinator.searchError != nil && coordinator.lastRequest.filters == filters && coordinator.lastRequest.page == 2, "failed retry preserves applied request despite edit")
        await fixture.setFailure(false)
        coordinator.retrySearch()
        try await wait(coordinator)
        check(coordinator.lastRequest.filters == filters && coordinator.lastRequest.page == 2, "successful retry preserves original request")
        coordinator.searchText = "forest"
        coordinator.applyFilters(filters)
        try await wait(coordinator)
        check(coordinator.lastRequest.page == 1 && coordinator.recentSearches == ["forest"], "apply resets page with true query history")
        coordinator.resetFilters()
        try await wait(coordinator)
        check(coordinator.filters.isEmpty && coordinator.lastRequest.filters.isEmpty && tags(coordinator.lastRequest) == ["Video"] && coordinator.lastRequest.page == 1, "reset clears filters keeps video scope")
        check(coordinator.lastRequest.query == "forest" && coordinator.recentSearches == ["forest"], "reset retains text without fabricated history")
        if CommandLine.arguments.count > 1 {
            let html = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            let request = WorkshopSearchRequest(filters: WorkshopSearchFilters(resolution: .size1920X1080, genre: .nature))
            let page = try WorkshopSSR.parseBrowsePage(html: html, request: request)
            check(!page.results.isEmpty, "live filtered SSR has actual results")
            check(page.results.allSatisfy { $0.isDeclaredVideo && !$0.isCollection }, "live SSR excludes unsupported types")
            check(page.results.allSatisfy { $0.tags.contains("1920 x 1080") && $0.tags.contains("Nature") }, "live Steam enforces both real filter tags")
            print("Live Steam filtered SSR: \(page.results.count) video results, total \(page.totalCount)")
        }
        print("WorkshopFilterTests passed: \(checks) checks")
    }
}
