import Foundation

/// 创意工坊「公开元数据」服务：搜索 + 作品详情。
///
/// 边界（重要）：
/// - 这里只做公开页面读取，**不涉及任何账号登录**；
/// - 网页登录状态与下载权限无关（F13 明确要求不得把 OpenID/网页会话当成下载认证）；
/// - 所有方法都是真实网络请求，失败时抛出带原因的错误，不返回伪造结果。
actor WorkshopService {
    static let shared = WorkshopService()
    private let http: SteamHTTPClient
    private var recentSearchPages: [(request: WorkshopSearchRequest, ids: [String])] = []
    private var unionCursor: WorkshopSearchUnion.Cursor?
    private var unionGeneration = UUID()
    private let searchPageLoader: (@Sendable (WorkshopSearchRequest) async throws -> WorkshopSearchPage)?
    private var unionCacheKey: WorkshopSearchRequest?
    private var recentAuthorPages: [(authorID: String, page: Int, ids: [String])] = []

    init(http: SteamHTTPClient = SteamHTTPClient(),
         searchPageLoader: (@Sendable (WorkshopSearchRequest) async throws -> WorkshopSearchPage)? = nil) {
        self.http = http
        self.searchPageLoader = searchPageLoader
    }

    /// F11：按关键词、类型、排序与分页搜索 Wallpaper Engine 作品。
    func search(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        let branches = request.filters.searchBranches
        guard branches.count > 1 else { return try await searchSingle(request) }
        var cacheKey = request
        cacheKey.page = 1
        if request.page == 1 || unionCacheKey != cacheKey {
            unionCursor = nil
            unionCacheKey = cacheKey
            unionGeneration = UUID()
        }
        let generation = unionGeneration
        var cursor = unionCursor ?? WorkshopSearchUnion.Cursor(request: cacheKey, filters: branches)
        let logicalPage = max(1, request.page)
        let pageSize = max(1, min(request.pageSize, 30))
        while cursor.pages.count < logicalPage && !cursor.finished {
            var results: [WorkshopSearchResult] = []
            while results.count < pageSize, let result = try await nextUnionResult(&cursor) {
                results.append(result)
            }
            // One item of lookahead tells us whether a full final page has a next
            // page. Keep it for the next call instead of requesting an empty page.
            if !cursor.finished { cursor.lookahead = try await nextUnionResult(&cursor) }
            if !results.isEmpty { cursor.pages.append(results) }
        }
        try Task.checkCancellation()
        if unionGeneration == generation { unionCursor = cursor }
        return WorkshopSearchPage(
            request: request,
            totalCount: cursor.seen.count,
            isTotalCountExact: cursor.finished,
            // Overlapping themes make summed branch totals inaccurate. The exact
            // page count becomes known when the lazy, deduplicated union ends.
            totalPages: cursor.finished ? cursor.pages.count : nil,
            results: logicalPage <= cursor.pages.count ? cursor.pages[logicalPage - 1] : [],
            discoveryPath: "union[\(branches.count)]"
        )
    }

    private func nextUnionResult(_ cursor: inout WorkshopSearchUnion.Cursor) async throws -> WorkshopSearchResult? {
        if let result = cursor.lookahead {
            cursor.lookahead = nil
            return result
        }
        while true {
            try Task.checkCancellation()
            switch cursor.next() {
            case .result(let result): return result
            case .fetch(let index, let request):
                cursor.accept(try await searchSingle(request), branch: index)
            case .end: return nil
            }
        }
    }

    private func searchSingle(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        if let searchPageLoader { return try await searchPageLoader(request) }
        let url = request.url
        WorkshopLog.info("工坊搜索：sort=\(request.sort.rawValue) page=\(max(1, request.page)) pageSize=\(request.pageSize) query=\(request.query.isEmpty ? "(空)" : "<关键词>")")
        let html = try await http.fetchPage(url)
        let page = try WorkshopSSR.parseBrowsePage(html: html, request: request)
        try Task.checkCancellation()
        let ids = page.results.map(\.id)
        if !ids.isEmpty, recentSearchPages.contains(where: { previous in
            var lhs = previous.request, rhs = request
            lhs.page = 1; rhs.page = 1
            return lhs == rhs && previous.request.page != request.page && previous.ids == ids
        }) {
            throw SteamHTTPError.structureChanged("Steam 为不同页码返回了完全相同的作品列表，请重试；未将重复页当作翻页成功。")
        }
        recentSearchPages.removeAll { $0.request == request }
        recentSearchPages.append((request, ids))
        if recentSearchPages.count > 8 { recentSearchPages.removeFirst(recentSearchPages.count - 8) }
        // 结果防御：确保所有条目都属于 Wallpaper Engine。
        let filtered = page.results.filter { result in
            guard let appID = result.consumerAppID else { return true }
            return appID == WorkshopInputValidator.wallpaperEngineAppID
        }
        return WorkshopSearchPage(
            request: page.request,
            totalCount: page.totalCount,
            totalPages: page.totalPages,
            results: filtered,
            discoveryPath: page.discoveryPath
        )
    }

    /// F12：按 ID 拉取作品详情并解析类型。
    func detail(itemID: WorkshopItemID) async throws -> WorkshopItemDetail {
        let html = try await http.fetchPage(itemID.detailsURL)
        let detail = try WorkshopItemPageParser.parse(html: html, requestedID: itemID.value)
        // 防御：详情页明确标注了其他 App 时直接拒绝。
        if let appID = detail.appID, appID != WorkshopInputValidator.wallpaperEngineAppID {
            throw WorkshopAccessError.notWallpaperEngineItem(appID: appID)
        }
        return detail
    }

    func authorWorks(author: WorkshopAuthor, page: Int) async throws -> WorkshopAuthorWorksPage {
        guard (1...100_000).contains(page) else { throw WorkshopInputError.invalidInput("作者作品页码无效。") }
        // English paging labels are explicitly requested so their numeric range
        // can be checked rather than assuming Steam honored the requested page.
        let html = try await http.fetchPage(author.worksURL(page: page), acceptLanguage: false)
        let result = try WorkshopAuthorPageParser.parse(html: html, author: author, page: page)
        try Task.checkCancellation()
        let ids = result.results.map(\.id)
        if !ids.isEmpty, recentAuthorPages.contains(where: { $0.authorID == author.id && $0.page != page && $0.ids == ids }) {
            throw SteamHTTPError.structureChanged("Steam 返回了重复的作者作品页，请重试。")
        }
        recentAuthorPages.removeAll { $0.authorID == author.id && $0.page == page }
        recentAuthorPages.append((author.id, page, ids))
        if recentAuthorPages.count > 12 { recentAuthorPages.removeFirst() }
        return result
    }

    /// F12：解析用户输入（URL 或纯数字 ID）并返回详情。
    ///
    /// - Throws: `WorkshopInputError`（输入不合法）或 `WorkshopAccessError`（类型不支持）。
    func resolve(input: String) async throws -> WorkshopItemDetail {
        let parsed = WorkshopInputValidator.parse(input)
        guard let itemID = parsed.itemIDValue else {
            throw WorkshopInputError.invalidInput(parsed.failureReason ?? "无法识别的工坊链接或 ID。")
        }
        let detail = try await detail(itemID: itemID)
        // 类型校验：不支持的壁纸类型在这里就被拒绝，并给出明确原因。
        if let reason = detail.kind.unsupportedReason {
            throw WorkshopAccessError.unsupportedKind(kind: detail.kind, reason: reason)
        }
        return detail
    }

    /// 拉取预览图数据（带缓存）。
    func previewImageData(for url: URL) async -> Data? {
        await WorkshopPreviewCache.shared.data(for: url)
    }
}

/// Produces deterministic logical pages without inventing a cross-type rank.
/// Each branch keeps Steam's order and round-robin interleaving gives every
/// selected branch stable representation across page boundaries.
enum WorkshopSearchUnion {
    /// Fetch branches only as they are visited. This avoids a Cartesian burst
    /// when many chips are selected and keeps already emitted logical pages stable.
    struct Cursor {
        struct Branch {
            var request: WorkshopSearchRequest
            var results: [WorkshopSearchResult] = []
            var offset = 0
            var exhausted = false
        }
        enum Step { case result(WorkshopSearchResult), fetch(Int, WorkshopSearchRequest), end }
        var branches: [Branch]
        var nextBranch = 0
        var seen = Set<String>()
        var pages: [[WorkshopSearchResult]] = []
        var lookahead: WorkshopSearchResult?
        var finished = false

        init(request: WorkshopSearchRequest, filters: [WorkshopSearchFilters]) {
            branches = filters.map { filters in
                var branch = request
                branch.filters = filters
                branch.page = 1
                return Branch(request: branch)
            }
        }

        mutating func next() -> Step {
            guard !finished else { return .end }
            var exhaustedBranches = 0
            while exhaustedBranches < branches.count {
                let index = nextBranch
                if branches[index].offset < branches[index].results.count {
                    let result = branches[index].results[branches[index].offset]
                    branches[index].offset += 1
                    nextBranch = (index + 1) % branches.count
                    exhaustedBranches = 0
                    if seen.insert(result.id).inserted { return .result(result) }
                } else if branches[index].exhausted {
                    nextBranch = (index + 1) % branches.count
                    exhaustedBranches += 1
                } else {
                    return .fetch(index, branches[index].request)
                }
            }
            finished = true
            return .end
        }

        mutating func accept(_ page: WorkshopSearchPage, branch index: Int) {
            branches[index].results = page.results
            branches[index].offset = 0
            branches[index].exhausted = !page.hasNextPage
            branches[index].request.page += 1
        }
    }
}

/// 输入错误（用户可修正）。
enum WorkshopInputError: LocalizedError, Equatable {
    case invalidInput(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let reason): return reason
        }
    }
}

/// 访问/类型错误（作品本身不适用）。
enum WorkshopAccessError: LocalizedError, Equatable {
    case unsupportedKind(kind: WorkshopItemKind, reason: String)
    case notWallpaperEngineItem(appID: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedKind(_, let reason):
            return reason
        case .notWallpaperEngineItem(let appID):
            return "该作品属于 AppID \(appID)，不是 Wallpaper Engine（\(WorkshopInputValidator.wallpaperEngineAppID)）的作品。"
        }
    }
}
