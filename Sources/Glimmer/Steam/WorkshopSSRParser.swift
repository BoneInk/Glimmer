import Foundation
import CoreFoundation

/// Steam 浏览页 SSR 解析。
///
/// 现状取证（2026-10-17 实测，见 evidence/steam-research.json）：
/// - `workshop/browse` 页面在 `<script id="valve-ssr-data">` 中内嵌多层 JSON，
///   真实结果位于 `renderContext.queryData`（本身是「字符串形式的 JSON」）
///   的 `queries[*].state.data`，含 `results` / `total_count` / `total_pages` 等字段。
/// - 旧式的 `workshopItemTitle` CSS 解析对浏览页**不适用**（那是详情页的结构）。
/// - 查询对象里的 `serverQuery` 只是**查询输入**，不是结果，绝不能当数据用。
///
/// 因此这里不做固定下标（`queries[15]`）假设，而是递归搜索「同时含 results 与 total_count 的查询缓存」。
enum WorkshopSSR {
    static let scriptID = "valve-ssr-data"

    /// 从 HTML 中取出 SSR JSON 脚本内容。
    static func extractScriptPayload(from html: String) -> String? {
        SteamHTML.scriptContent(in: html, id: scriptID)
    }

    /// 解析浏览页 HTML → 搜索页结果。
    ///
    /// - Throws: `SteamHTTPError.structureChanged` 当页面结构不符合已知形态时（不伪造空结果）。
    static func parseBrowsePage(html: String, request: WorkshopSearchRequest) throws -> WorkshopSearchPage {
        guard let payload = extractScriptPayload(from: html) else {
            throw SteamHTTPError.structureChanged("页面中没有找到 script#\(scriptID)（Steam 可能更换了渲染方式）")
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(payload.utf8), options: [.allowFragments]) else {
            throw SteamHTTPError.decoding("script#\(scriptID) 不是有效 JSON")
        }

        var search = SearchCollector()
        search.walk(root, path: "root")

        let identified = search.hits.filter { $0.query != nil }
        let matches = identified.filter { matchesRequest($0, request: request) }
        let hit: SearchHit?
        if !identified.isEmpty {
            hit = matches.first
        } else if search.hits.count == 1, let candidate = search.hits.first,
                  (number(candidate.data["current_page"]) == max(1,request.page)
                   || (candidate.data["current_page"] == nil && request.page == 1)) {
            // Old single-result fixture/schema compatibility is first-page-only
            // unless the response explicitly identifies its actual current page.
            hit = candidate
        } else { hit = nil }
        guard let hit else {
            // 给出取证线索，便于诊断：列出发现的查询键。
            let keys = search.queryKeys.prefix(8).joined(separator: ", ")
            throw SteamHTTPError.structureChanged(
                "SSR 没有与当前页码、热榜时间及筛选条件匹配的作品结果（拒绝将其他页显示为当前页）" + (keys.isEmpty ? "" : "（已发现查询键：\(keys)）")
            )
        }
        return try buildPage(from: hit.data, path: hit.path, request: request)
    }

    // MARK: - 递归搜索

    private struct SearchHit {
        var path: String
        var data: [String: Any]
        var query: [String: Any]?
    }

    private struct SearchCollector {
        var hits: [SearchHit] = []
        var queryKeys: [String] = []

        mutating func walk(_ value: Any, path: String, depth: Int = 0, query: [String: Any]? = nil) {
            guard depth < 24 else { return }
            if let string = value as? String {
                // SSR 里大量字段是「字符串形式的 JSON」，需要再解一层。
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), trimmed.count > 2 else { return }
                if let nested = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.allowFragments]) {
                    walk(nested, path: path + "(decoded)", depth: depth + 1, query: query)
                }
                return
            }
            if let dictionary = value as? [String: Any] {
                var context = query
                if let key = dictionary["queryKey"] as? [Any], key.first as? String == "workshop_browse", key.count > 1 {
                    context = key[1] as? [String: Any]
                }
                if let results = dictionary["results"], let total = dictionary["total_count"],
                   (results is [Any] || results is [String]), total is NSNumber {
                    hits.append(SearchHit(path: path, data: dictionary, query: context))
                }
                if let queryKey = dictionary["queryKey"] as? [Any], let first = queryKey.first as? String {
                    if queryKeys.count < 24 { queryKeys.append(first) }
                }
                for key in dictionary.keys.sorted() {
                    walk(dictionary[key]!, path: path + "." + key, depth: depth + 1, query: context)
                }
                return
            }
            if let array = value as? [Any] {
                for (index, child) in array.enumerated() {
                    walk(child, path: path + "[\(index)]", depth: depth + 1, query: query)
                }
            }
        }
    }

    private static func number(_ raw: Any?) -> Int? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
              n.doubleValue >= 0, n.doubleValue <= Double(Int32.max) else { return nil }
        return n.intValue
    }
    private static func matchesRequest(_ hit: SearchHit, request: WorkshopSearchRequest) -> Bool {
        guard let query = hit.query,
              number(query["appid"]) == WorkshopInputValidator.wallpaperEngineAppID,
              number(query["page"]) == max(1,request.page),
              query["browse_sort"] as? String == request.sort.steamBrowseValue,
              query["search_text"] as? String == request.query.trimmingCharacters(in:.whitespacesAndNewlines),
              let tags = query["required_tags"] as? [String] else { return false }
        if let actual = hit.data["current_page"], number(actual) != max(1,request.page) { return false }
        let expected = (request.filters.type.requiredTag.map { [$0] } ?? []) + request.filters.requiredTags
        guard Set(tags.map { $0.lowercased() }) == Set(expected.map { $0.lowercased() }) else { return false }
        if request.sort == .trend, number(query["trend_days"]) != request.filters.trendPeriod.rawValue { return false }
        // Steam currently normalizes unsupported numperpage values (24/18) to
        // 30. Page identity is validated against the actual response, not a
        // fabricated local page-size assumption.
        return true
    }

    // MARK: - 结果构造

    private static func buildPage(from data: [String: Any], path: String, request: WorkshopSearchRequest) throws -> WorkshopSearchPage {
        var results: [WorkshopSearchResult] = []
        var rawResults: [Any] = []
        if let array = data["results"] as? [Any] {
            rawResults = array
        } else if let jsonString = data["results"] as? String,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [Any] {
            rawResults = decoded
        }

        for raw in rawResults {
            guard let dictionary = raw as? [String: Any] else { continue }
            if let item = makeResult(from: dictionary) {
                results.append(item)
            }
        }

        let totalCount = (data["total_count"] as? NSNumber)?.intValue ?? results.count
        let totalPages = (data["total_pages"] as? NSNumber)?.intValue

        // Match the requested type; all can show unsupported individual items
        // without advertising them as downloadable or playable.
        let matchingTypes = results.filter(request.filters.type.includes)

        return WorkshopSearchPage(
            request: request,
            totalCount: totalCount,
            totalPages: totalPages,
            results: matchingTypes,
            discoveryPath: path
        )
    }

    private static func makeResult(from dictionary: [String: Any]) -> WorkshopSearchResult? {
        guard let publishedFileID = stringValue(dictionary["publishedfileid"]) ?? intStringValue(dictionary["publishedfileid"]) else {
            return nil
        }
        let tags: [String] = (dictionary["tags"] as? [Any])?.compactMap { entry -> String? in
            if let entry = entry as? [String: Any] {
                return (entry["tag"] as? String) ?? (entry["display_name"] as? String)
            }
            return entry as? String
        } ?? []

        let childCount = (dictionary["num_children"] as? NSNumber)?.intValue ?? 0

        let previewURL: URL? = {
            guard let raw = dictionary["preview_url"] as? String, !raw.isEmpty else { return nil }
            return URL(string: raw)
        }()

        let timeCreated = (dictionary["time_created"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let timeUpdated = (dictionary["time_updated"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }

        let fileSize: Int64? = {
            if let number = dictionary["file_size"] as? NSNumber { return number.int64Value }
            if let text = dictionary["file_size"] as? String { return Int64(text) }
            return nil
        }()

        let starRating: Double? = (dictionary["star_rating"] as? NSNumber).map { $0.doubleValue }
        let totalVotes = (dictionary["total_votes"] as? NSNumber)?.intValue

        return WorkshopSearchResult(
            publishedFileID: publishedFileID,
            title: (dictionary["title"] as? String) ?? "(无标题)",
            shortDescription: (dictionary["short_description"] as? String) ?? "",
            consumerAppID: (dictionary["consumer_appid"] as? NSNumber)?.intValue,
            previewURL: previewURL,
            timeCreated: timeCreated,
            timeUpdated: timeUpdated,
            fileSizeBytes: fileSize,
            tags: tags,
            subscriptions: (dictionary["subscriptions"] as? NSNumber)?.intValue,
            favorited: (dictionary["favorited"] as? NSNumber)?.intValue,
            views: (dictionary["views"] as? NSNumber)?.intValue,
            commentCount: (dictionary["num_comments_public"] as? NSNumber)?.intValue,
            starRating: (starRating ?? -1) < 0 ? nil : starRating,
            totalVotes: (totalVotes ?? 0) > 0 ? totalVotes : nil,
            childCount: childCount,
            isCollection: childCount > 0 || tags.contains { $0.caseInsensitiveCompare("Collection") == .orderedSame }
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func intStringValue(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
