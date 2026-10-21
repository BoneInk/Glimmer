import Foundation

actor SearchFixture {
    var calls: [WorkshopSearchRequest] = []
    var failQueries = true
    func setFailQueries(_ value: Bool) { failQueries = value }
    func search(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        calls.append(request)
        if request.query == "pending" { try await Task.sleep(for: .seconds(1)) }
        if request.query == "fail", failQueries { throw URLError(.cannotConnectToHost) }
        return WorkshopSearchPage(request: request, totalCount: 50, totalPages: 3,
                                  results: [WorkshopSearchResult(publishedFileID: "1", title: request.query, shortDescription: "", tags: ["Video"], childCount: 0, isCollection: false)], discoveryPath: "fixture")
    }
    func slowSearch(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        calls.append(request)
        try await Task.sleep(for: .seconds(1))
        return WorkshopSearchPage(request: request, totalCount: 0, results: [], discoveryPath: "cancel-fixture")
    }
    var count: Int { calls.count }
}

@main struct WorkshopBrowserTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { fatalError("FAIL: \(label)") }
        }
        func presentation(_ state: WorkshopDownloadState, staleProgress: Double? = nil) -> WorkshopDownloadProgressPresentation {
            var item = WorkshopDownloadItem(publishedFileID: "ring", title: "Ring", kind: .video, declaredTags: ["Video"])
            item.state = state
            item.progressFraction = staleProgress
            return WorkshopDownloadProgressPresentation(item: item)
        }
        let idle = WorkshopDownloadProgressPresentation(item: nil)
        check(idle.ring == .none && !idle.downloadDisabled && idle.statusText == nil, "idle download has no progress")
        for value in [0.0, 0.42, 1.0] {
            let actual = presentation(.downloading(fraction: value, text: "bytes"))
            check(actual.ring == .determinate(value) && actual.symbolName == "pause" && !actual.downloadDisabled && actual.statusText == "下载中 \(String(format: "%.0f%%", value * 100))", "actual download fraction \(value) retains measured ring with actionable pause")
        }
        check(presentation(.downloading(fraction: -0.1, text: "")).ring == .determinate(0), "negative fraction clamped")
        check(presentation(.downloading(fraction: 1.4, text: "")).ring == .determinate(1), "overflow fraction clamped")
        for value in [Double?.none, .some(.nan), .some(.infinity), .some(-.infinity)] {
            let unknown = presentation(.downloading(fraction: value, text: ""), staleProgress: 0.9)
            check(unknown.ring == .indeterminate && unknown.symbolName == "pause" && !unknown.downloadDisabled && !unknown.accessibilityValue.contains("%"), "unknown progress offers pause without invented percent")
        }
        let waiting = presentation(.queued, staleProgress: 0.42)
        check(waiting.ring == .waiting && waiting.symbolName == "clock" && waiting.downloadDisabled, "queued uses static waiting ring")
        let pausing = presentation(.pausing, staleProgress: 0.42)
        check(pausing.ring == .indeterminate && pausing.downloadDisabled && pausing.statusText == "正在暂停", "pause waits for actual executor cleanup")
        let paused = presentation(.paused, staleProgress: 0.42)
        check(paused.ring == .determinate(0.42) && paused.symbolName == "play.fill" && !paused.downloadDisabled && paused.actionTitle == "继续下载", "paused retains measured progress and offers continue")
        check(presentation(.paused).ring == .none && !presentation(.paused).accessibilityValue.contains("%"), "paused without measured progress invents no fraction")
        check(presentation(.downloading(fraction: nil, text: "")).actionTitle == "暂停下载", "active cover button labels its pause action")
        let validating = presentation(.validating("video"), staleProgress: 1)
        check(validating.ring == .indeterminate && validating.statusText == "正在校验" && !validating.accessibilityValue.contains("%"), "validation never reuses completed download fraction")
        let complete = presentation(.completed, staleProgress: 1)
        check(complete.ring == .none && complete.symbolName == "checkmark" && complete.statusText == "已下载" && complete.downloadDisabled, "completed retains checkmark and downloaded text without stale progress ring")
        for state: WorkshopDownloadState in [.failed(message: "offline"), .cancelled] {
            let retry = presentation(state, staleProgress: 0.42)
            check(retry.ring == .none && !retry.downloadDisabled, "terminal retry clears stale ring")
        }
        check(presentation(.downloading(fraction: 0.42, text: "")) != presentation(.downloading(fraction: 0.68, text: "")), "new coordinator fraction changes presentation without local state")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("browser.json")
        func result(_ id: String, tags: [String] = ["Video"]) -> WorkshopSearchResult {
            WorkshopSearchResult(publishedFileID: id, title: "Video \(id)", shortDescription: "public",
                consumerAppID: 431960, tags: tags, childCount: 0, isCollection: false)
        }
        var store = WorkshopBrowserStore(persistenceURL: url)
        for n in 0..<15 { store.recordSuccessfulSearch("q\(n)") }
        check(store.recentSearches.count == 12 && store.recentSearches.first == "q14", "bounded history")
        store.recordSuccessfulSearch(" Q14 ")
        check(store.recentSearches.count == 12 && store.recentSearches.first == "Q14", "normalized case insensitive history")
        store.recordSuccessfulSearch("")
        store.recordSuccessfulSearch(String(repeating: "x", count: 201))
        store.recordSuccessfulSearch("line\nbreak")
        check(store.recentSearches.count == 12 && store.recentSearches.first == "Q14", "invalid history rejected")
        store.toggleSaved(result("000123"))
        store.toggleSaved(result("bad"))
        store.toggleSaved(result("124", tags: ["Web"]))
        check(store.savedResults.count == 2 && store.isSaved("123") && store.savedResults.first?.declaredKind == .web, "saved ID validation preserves actual Web type")
        let loaded = WorkshopBrowserStore(persistenceURL: url)
        check(loaded.recentSearches == store.recentSearches && loaded.savedResults == store.savedResults, "atomic persistence roundtrip")
        store.toggleSaved(result("123"))
        store.toggleSaved(result("124", tags: ["Web"]))
        check(store.savedResults.isEmpty, "toggle removes")
        for n in 1...205 { store.toggleSaved(result(String(n))) }
        check(store.savedResults.count == 200 && store.savedResults.first?.id == "205", "saved limit")
        store.clearSearchHistory()
        check(WorkshopBrowserStore(persistenceURL: url).recentSearches.isEmpty, "clear history persisted")
        try Data("bad JSON".utf8).write(to: url)
        check(WorkshopBrowserStore(persistenceURL: url).savedResults.isEmpty, "corrupt input ignored")
        try Data("{\"schemaVersion\":99,\"recentSearches\":[\"old\"],\"savedResults\":[]}".utf8).write(to: url)
        check(WorkshopBrowserStore(persistenceURL: url).recentSearches.isEmpty, "unknown version ignored")
        var memoryStore = WorkshopBrowserStore(persistenceURL: nil)
        var invalidURL = result("999")
        invalidURL.previewURL = URL(string: "file:///private/credential")
        memoryStore.toggleSaved(invalidURL)
        check(memoryStore.savedResults.first?.previewURL == nil, "local thumbnail URL removed")
        var foreign = result("888")
        foreign.consumerAppID = 1
        memoryStore.toggleSaved(foreign)
        check(memoryStore.savedResults.count == 1, "wrong app rejected")
        var malformed = result("777")
        malformed.isCollection = true
        memoryStore.toggleSaved(malformed)
        check(memoryStore.savedResults.count == 1, "collection rejected")
        // Invalid records in an otherwise decodable document are sanitized independently.
        let raw = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "recentSearches": [" a ", "A", "", "b"],
            "savedResults": try JSONSerialization.jsonObject(with: JSONEncoder().encode([result("bad"), result("1"), result("1"), result("2", tags: ["Web"])]))])
        try raw.write(to: url)
        let cleaned = WorkshopBrowserStore(persistenceURL: url)
        check(cleaned.recentSearches == ["a", "b"] && cleaned.savedResults.map(\.id) == ["1", "2"] && cleaned.savedResults.last?.declaredKind == .web, "decoded invalid records filtered while genuine Web saved metadata retained")

        var oversized = result("666")
        oversized.title = String(repeating: "字", count: 1_000)
        oversized.shortDescription = String(repeating: "字", count: 5_000)
        oversized.tags = Array(repeating: "other", count: 40) + ["Video"]
        memoryStore.toggleSaved(oversized)
        check(memoryStore.savedResults.first?.title.count == 512 && memoryStore.savedResults.first?.shortDescription.count == 4_000 && memoryStore.savedResults.first?.tags.count == 32 && memoryStore.savedResults.first?.isDeclaredVideo == true, "public text bounds retain video type")

        let fixture = SearchFixture()
        let account = SteamAccountManager(layout: SteamCMDLayout(root: root.appendingPathComponent("SteamCMD")))
        let coordinator = WorkshopCoordinator(account: account, browserStore: WorkshopBrowserStore(persistenceURL: nil),
            searchOperation: { request in try await fixture.search(request) }, queuePersistence: .disabled)
        func settle() async {
            for _ in 0..<100 where coordinator.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        }
        coordinator.ensureDiscoveryLoaded()
        await settle()
        coordinator.ensureDiscoveryLoaded()
        check(await fixture.count == 1, "discovery one shot")
        check(coordinator.lastRequest.query.isEmpty && coordinator.lastRequest.sort == .trend && coordinator.recentSearches.isEmpty, "discovery does not record history")
        coordinator.searchText = "  anime  "
        coordinator.search()
        await settle()
        check(coordinator.recentSearches == ["anime"], "successful explicit search recorded")
        coordinator.nextPage()
        await settle()
        check(coordinator.lastRequest.page == 2 && coordinator.recentSearches == ["anime"], "pagination preserved")
        check(!coordinator.results.isEmpty && coordinator.totalCount == 50 && coordinator.canGoToNextPage, "successful page has matching cards and pagination")
        coordinator.searchText = "fail"
        coordinator.search(resetPage: false)
        check(coordinator.isSearching && coordinator.results.isEmpty && coordinator.totalCount == 0 && coordinator.totalPages == nil && !coordinator.canGoToNextPage && !coordinator.canGoToPreviousPage, "pending request clears old cards and pagination")
        await settle()
        check(coordinator.searchError != nil && coordinator.recentSearches == ["anime"], "failed search not recorded")
        check(coordinator.lastRequest.page == 2 && coordinator.results.isEmpty && coordinator.totalCount == 0 && coordinator.totalPages == nil && !coordinator.canGoToNextPage, "failed page never retains old cards or totals")
        coordinator.nextPage()
        check(coordinator.lastRequest.page == 2, "failed page cannot skip ahead")
        let failedRequest = coordinator.lastRequest
        coordinator.searchText = "edited but unsubmitted"
        coordinator.sort = .mostrecent
        coordinator.pageSize = 6
        await fixture.setFailQueries(false)
        coordinator.retrySearch()
        await settle()
        check(coordinator.lastRequest == failedRequest && coordinator.results.first?.title == "fail", "retry preserves failed query sort page size and page despite edited inputs")
        check(coordinator.recentSearches.first == "fail", "successful explicit retry records query history")
        coordinator.searchText = "pending"
        coordinator.search(resetPage: false)
        check(coordinator.results.isEmpty && coordinator.totalPages == nil && !coordinator.canGoToNextPage, "pending replacement hides successful retry results")
        coordinator.cancelSearch()
        check(!coordinator.isSearching && coordinator.results.isEmpty && coordinator.totalCount == 0 && coordinator.totalPages == nil && !coordinator.canGoToNextPage && !coordinator.canGoToPreviousPage, "cancelled request has no stale cards or page navigation")
        let cancelledFixture = SearchFixture()
        let cancelled = WorkshopCoordinator(account: account, browserStore: WorkshopBrowserStore(persistenceURL: nil),
            searchOperation: { request in try await cancelledFixture.slowSearch(request) }, queuePersistence: .disabled)
        cancelled.ensureDiscoveryLoaded()
        for _ in 0..<100 {
            if await cancelledFixture.count > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        cancelled.cancelSearch()
        cancelled.ensureDiscoveryLoaded()
        try? await Task.sleep(for: .milliseconds(20))
        check(await cancelledFixture.count == 1 && !cancelled.isSearching && cancelled.lastSearchedAt == nil, "cancelled discovery never auto repeats")
        coordinator.clearSearchHistory()
        check(coordinator.recentSearches.isEmpty, "coordinator clears history")
        coordinator.toggleSaved(result("42"))
        check(coordinator.isSaved("42"), "coordinator saved facade")

        func item(_ id: String, _ state: WorkshopDownloadState) -> WorkshopDownloadItem {
            var item = WorkshopDownloadItem(publishedFileID: id, title: "Item \(id)", kind: .video,
                declaredTags: ["Video"], previewImageURLString: nil, fileSizeBytes: nil)
            item.state = state
            return item
        }
        coordinator.downloadProgress.items = [item("1", .downloading(fraction: nil, text: "active")),
            item("2", .queued), item("3", .completed), item("4", .queued), item("5", .failed(message: "fixture")), item("6", .cancelled)]
        coordinator.downloadProgress.activeItemID = "1"
        coordinator.moveQueuedDownload(itemID: "4", direction: .up)
        check(coordinator.downloadProgress.items.map(\.id) == ["1", "4", "3", "2", "5", "6"], "reorder queued slots only")
        coordinator.moveQueuedDownload(itemID: "1", direction: .down)
        check(coordinator.downloadProgress.items.first?.id == "1", "active never reordered")
        coordinator.retryDownload(itemID: "3")
        check(coordinator.downloadProgress.items[2].state == .completed, "completed never retried")
        coordinator.retryFailedDownloads()
        check(coordinator.downloadProgress.items.filter { $0.state == .queued }.count == 4, "batch retry failed and cancelled only")
        check(coordinator.downloadProgress.items.allSatisfy { $0.attempts == 0 }, "attempt count waits for actual start")
        coordinator.cancelQueuedDownloads()
        check(coordinator.downloadProgress.items.filter { $0.state == .cancelled }.count == 4 && coordinator.downloadProgress.items[0].state == .downloading(fraction: nil, text: "active"), "cancel queued preserves active")

        let video = root.appendingPathComponent("fixture.mp4")
        try Data([1, 2, 3]).write(to: video)
        var completed = item("99", .completed)
        completed.project = WorkshopVideoProject(videoURL: video, videoRelativePath: "fixture.mp4", projectJSONPath: "project.json",
            projectRoot: root, projectType: "video", projectTitle: "Verified title", workshopID: "99", declaredTags: ["Video"], videoByteSize: 3,
            probe: VideoProbeResultSummary(isPlayable: true, durationSeconds: 1, pixelWidth: 2, pixelHeight: 2, hasAudioTrack: false), diagnostics: [])
        coordinator.downloadProgress.items = [completed]
        check(coordinator.localPreview(for: "99")?.fileURL == video, "completed existing validated video eligible")
        coordinator.removeDownload(itemID: "99")
        check(coordinator.downloadProgress.items.isEmpty && FileManager.default.fileExists(atPath: root.path) && (try? Data(contentsOf: video)) == Data([1, 2, 3]), "remove terminal record preserves directory and video bytes")
        coordinator.downloadProgress.items = [completed]
        coordinator.downloadProgress.activeItemID = "99"
        coordinator.removeDownload(itemID: "99")
        check(coordinator.downloadProgress.items.count == 1, "active record cannot be removed even if terminal callback arrived")
        coordinator.downloadProgress.activeItemID = nil
        coordinator.downloadProgress.items[0].state = .queued
        check(coordinator.localPreview(for: "99") == nil, "incomplete project ineligible")
        coordinator.removeDownload(itemID: "99")
        check(coordinator.downloadProgress.items.count == 1 && (try? Data(contentsOf: video)) == Data([1, 2, 3]), "queued record cannot be removed")
        coordinator.downloadProgress.items[0].state = .completed
        coordinator.downloadProgress.items[0].project?.projectType = "scene"
        check(coordinator.localPreview(for: "99") == nil, "nonvideo project ineligible")
        coordinator.downloadProgress.items[0].project?.projectType = "video"
        coordinator.downloadProgress.items[0].project?.probe.isPlayable = false
        check(coordinator.localPreview(for: "99") == nil, "unplayable project ineligible")
        coordinator.downloadProgress.items[0].project?.probe.isPlayable = true
        try FileManager.default.removeItem(at: video)
        check(coordinator.localPreview(for: "99") == nil, "deleted video ineligible")
        try FileManager.default.createDirectory(at: video, withIntermediateDirectories: true)
        check(coordinator.localPreview(for: "99") == nil, "directory replacing video ineligible")
        check(coordinator.localPreview(for: "missing") == nil, "unknown item ineligible")
        print("WorkshopBrowserTests: \(checks) checks passed; temp-only, no login/download/network")
    }
}
