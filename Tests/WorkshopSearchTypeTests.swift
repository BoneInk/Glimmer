import Foundation

@main struct WorkshopSearchTypeTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) { checks += 1; precondition(condition, label) }
        func query(_ filters: WorkshopSearchFilters) -> [URLQueryItem] {
            URLComponents(url: WorkshopSearchRequest(query: "Web & 雨", filters: filters).url, resolvingAgainstBaseURL: false)!.queryItems!
        }
        func tags(_ filters: WorkshopSearchFilters) -> [String] { query(filters).filter { $0.name.hasPrefix("requiredtags[") }.compactMap(\.value) }
        check(tags(.init()) == ["Video"], "legacy default request still requires Video tag")
        check(WorkshopSearchFilters().isEmpty, "legacy default has no extra active filter")
        var web = WorkshopSearchFilters(type: .web, resolution: .size1920X1080, genre: .nature)
        check(tags(web) == ["Web", "1920 x 1080", "Nature"], "Web type combines genuine Steam tags")
        check(query(web).filter { $0.name.hasPrefix("requiredtags[") }.map(\.name) == ["requiredtags[0]", "requiredtags[1]", "requiredtags[2]"], "Web query tag indices remain contiguous")
        check(web.activeCount == 3 && web.activeLabels.first == "类型：Web", "nondefault type participates in active filter UI")
        web.type = .all
        check(tags(web) == ["1920 x 1080", "Nature"], "all types removes only type requirement")
        check(query(web).filter { $0.name.hasPrefix("requiredtags[") }.map(\.name) == ["requiredtags[0]", "requiredtags[1]"], "all types with other filters starts at index zero")
        check(tags(.init(type: .all)).isEmpty, "all types never sends a hidden Video tag")
        let multi = WorkshopSearchFilters(types: [.video, .web], genre: .nature)
        check(multi.orderedTypes == [.video, .web] && multi.type == .all, "multi-type selection keeps deterministic branch order and legacy bridge")
        check(tags(WorkshopSearchRequest(filters: multi).specialized(for: .web).filters) == ["Web", "Nature"], "type branch preserves shared genre constraint")
        let everyType = WorkshopSearchFilters(types: Set(WorkshopSearchType.selectableCases), genre: .nature)
        check(everyType.type == .all && tags(everyType) == ["Nature"], "all selectable types collapse to genuine all-type query semantics")
        check(query(web).first { $0.name == "searchtext" }?.value == "Web & 雨", "type changes preserve correctly encoded search text")
        let entries: [[String: Any]] = [
            ["publishedfileid": "1", "title": "Video", "tags": ["Video"], "consumer_appid": 431960],
            ["publishedfileid": "2", "title": "Web", "tags": ["Nature", "Web"], "consumer_appid": 431960],
            ["publishedfileid": "3", "title": "Scene", "tags": ["Scene"], "consumer_appid": 431960],
            ["publishedfileid": "4", "title": "Application", "tags": ["Application"], "consumer_appid": 431960],
            ["publishedfileid": "5", "title": "Unknown", "tags": ["Nature"], "consumer_appid": 431960],
            ["publishedfileid": "6", "title": "Collection", "tags": ["Collection"], "num_children": 2],
            ["publishedfileid": "7", "title": "Lowercase Web", "tags": ["web"]],
            ["publishedfileid": "8", "title": "Lowercase Collection", "tags": ["collection"]]
        ]
        let bytes = try JSONSerialization.data(withJSONObject: ["renderContext": ["queryData": ["results": entries, "total_count": 99, "total_pages": 5]]])
        let html = "<script id='valve-ssr-data' type='application/json'>" + String(decoding: bytes, as: UTF8.self) + "</script>"
        let videos = try WorkshopSSR.parseBrowsePage(html: html, request: .init())
        check(videos.results.map(\.id) == ["1"], "default parser retains only actual declared Video")
        let webs = try WorkshopSSR.parseBrowsePage(html: html, request: .init(filters: .init(type: .web)))
        check(webs.results.map(\.id) == ["2", "7"] && webs.results.allSatisfy { $0.declaredKind == .web }, "Web parser preserves real type including case variants")
        check(tags(.init(type: .scene)) == ["Scene"], "Scene query sends the actual Steam type tag")
        let scenes = try WorkshopSSR.parseBrowsePage(html: html, request: .init(filters: .init(type: .scene)))
        check(scenes.results.map(\.id) == ["3"] && scenes.results.allSatisfy { $0.declaredKind == .scene }, "Scene parser preserves real type and excludes unrelated candidates")
        let all = try WorkshopSSR.parseBrowsePage(html: html, request: .init(filters: .init(type: .all)))
        check(all.results.map(\.id) == ["1", "2", "3", "4", "5", "7"], "all types shows unsupported individual items but excludes collections")
        check(all.totalCount == 99 && all.totalPages == 5, "server pagination metadata is preserved rather than invented")
        check(all.results.first { $0.id == "3" }?.isSupportedWallpaper == true && all.results.first { $0.id == "4" }?.isSupportedWallpaper == false, "Scene is a validation candidate while Application remains unsupported")
        check(all.results.first { $0.id == "5" }?.declaredKind == .unknown && all.results.first { $0.id == "5" }?.isSupportedWallpaper == true, "unknown page type remains unknown pending actual project validation")
        let directory = URL(fileURLWithPath: "/private/tmp/gw-type-browser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("browser.json")
        var store = WorkshopBrowserStore(persistenceURL: file)
        let originalWeb = webs.results[0]
        store.toggleSaved(originalWeb)
        check(store.savedResults.first?.declaredKind == .web && store.savedResults.first?.tags.contains("Video") == false, "saving Web never adds a Video tag")
        check(store.savedResults.first?.tags.contains("Nature") == true, "saving Web retains author genre tags")
        var reloaded = WorkshopBrowserStore(persistenceURL: file)
        check(reloaded.savedResults == store.savedResults && reloaded.savedResults.first?.declaredKind == .web, "Web saved metadata persists across restart")
        reloaded.toggleSaved(originalWeb)
        check(reloaded.savedResults.isEmpty, "Web saved toggle removal works")
        let old = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "recentSearches": ["rain"], "savedResults": try JSONSerialization.jsonObject(with: JSONEncoder().encode(videos.results))])
        try old.write(to: file)
        let legacy = WorkshopBrowserStore(persistenceURL: file)
        check(legacy.savedResults.first?.declaredKind == .video && legacy.recentSearches == ["rain"], "old schema1 video saves remain compatible")
        var removable = legacy
        removable.removeRecentSearch("RAIN")
        check(removable.recentSearches.isEmpty && WorkshopBrowserStore(persistenceURL: file).recentSearches.isEmpty, "single history removal is case-insensitive and persisted")
        store.toggleSaved(all.results.first { $0.id == "3" }!)
        check(store.savedResults.first?.declaredKind == .scene && store.savedResults.first?.isSupportedWallpaper == true, "saved Scene candidate retains real type for later subset validation")
        let beforeCollections = store.savedResults.count
        var collection = originalWeb; collection.publishedFileID = "10"; collection.isCollection = true
        store.toggleSaved(collection)
        check(store.savedResults.count == beforeCollections, "collections are never converted to playable saved items")
        collection.isCollection = false; collection.tags = ["collection"]
        store.toggleSaved(collection)
        check(store.savedResults.count == beforeCollections, "case variant collection tags cannot bypass saved item exclusion")
        print("WorkshopSearchTypeTests: \(checks) passed; query types, SSR filtering, truthful support labels and backward-compatible saved metadata; no network or account IO")
    }
}
