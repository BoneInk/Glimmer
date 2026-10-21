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
        filters.type = .web
        check(tags(WorkshopSearchRequest(filters: filters)).first == "Web", "Web filter selected before coordinator pagination and retry regression")
        func result(_ id: String, _ type: String) -> WorkshopSearchResult {
            .init(publishedFileID: id, title: id, shortDescription: "", tags: [type], childCount: 0, isCollection: false)
        }
        var unionRequest = WorkshopSearchRequest(page: 1, pageSize: 2, filters: .init(types: [.video, .web], genre: .nature))
        let branches = [[result("v1", "Video"), result("v2", "Video"), result("v3", "Video")],
                        [result("w1", "Web"), result("w2", "Web"), result("w3", "Web")]]
        let unionFirst = WorkshopSearchUnion.merge(request: unionRequest, branches: branches, reportedTotal: 6, discoveryPaths: ["video", "web"])
        unionRequest.page = 2
        let unionSecond = WorkshopSearchUnion.merge(request: unionRequest, branches: branches, reportedTotal: 6, discoveryPaths: ["video", "web"])
        check(unionFirst.results.map(\.id) == ["v1", "w1"] && unionSecond.results.map(\.id) == ["v2", "w2"], "multi-type pagination is stable and does not repeat the first logical page")
        check(unionSecond.totalCount == 6 && unionSecond.totalPages == 3 && unionSecond.hasNextPage, "multi-type union exposes truthful summed partition pagination")
        let duplicateBranches = [[result("same", "Video"), result("v2", "Video")], [result("same", "Web"), result("w2", "Web")]]
        let deduplicated = WorkshopSearchUnion.merge(request: WorkshopSearchRequest(pageSize: 4, filters: .init(types: [.video, .web])), branches: duplicateBranches, reportedTotal: 4, discoveryPaths: [])
        check(deduplicated.results.map(\.id) == ["same", "v2", "w2"] && deduplicated.totalCount == 3 && deduplicated.totalPages == 1, "cross-type duplicate IDs are removed from cards and pagination totals")
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
