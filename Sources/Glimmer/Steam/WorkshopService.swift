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
    private var unionPageCache: [(request: WorkshopSearchRequest, page: WorkshopSearchPage)] = []
    private var unionCacheKey: WorkshopSearchRequest?
    private var recentAuthorPages: [(authorID: String, page: Int, ids: [String])] = []

    init(http: SteamHTTPClient = SteamHTTPClient()) {
        self.http = http
    }

    /// F11：按关键词、类型、排序与分页搜索 Wallpaper Engine 作品。
    func search(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
        let types = request.filters.orderedTypes
        guard types.count > 1, types.count < WorkshopSearchType.selectableCases.count else {
            return try await searchSingle(request)
        }

        let logicalPage = max(1, request.page)
        var cacheKey = request
        cacheKey.page = 1
        if request.page == 1 || unionCacheKey != cacheKey {
            unionPageCache.removeAll()
            unionCacheKey = cacheKey
        }
        var branches: [[WorkshopSearchResult]] = []
        var totalCount = 0
        var paths: [String] = []

        for type in types {
            var accumulated: [WorkshopSearchResult] = []
            var branchTotalPages: Int?
            for pageNumber in 1...logicalPage {
                try Task.checkCancellation()
                if let branchTotalPages, pageNumber > branchTotalPages { break }
                let branchRequest = request.specialized(for: type, page: pageNumber)
                let page: WorkshopSearchPage
                if let cached = unionPageCache.first(where: { $0.request == branchRequest })?.page {
                    page = cached
                } else {
                    page = try await searchSingle(branchRequest)
                    unionPageCache.append((branchRequest, page))
                    if unionPageCache.count > 90 { unionPageCache.removeFirst(unionPageCache.count - 90) }
                }
                if pageNumber == 1 {
                    totalCount += page.totalCount
                    branchTotalPages = page.totalPages
                    paths.append("\(type.rawValue):\(page.discoveryPath)")
                }
                accumulated.append(contentsOf: page.results)
            }
            branches.append(accumulated)
        }

        return WorkshopSearchUnion.merge(
            request: request,
            branches: branches,
            reportedTotal: totalCount,
            discoveryPaths: paths
        )
    }

    private func searchSingle(_ request: WorkshopSearchRequest) async throws -> WorkshopSearchPage {
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
/// selected type stable representation across page boundaries.
enum WorkshopSearchUnion {
    static func merge(request: WorkshopSearchRequest,
                      branches: [[WorkshopSearchResult]],
                      reportedTotal: Int,
                      discoveryPaths: [String]) -> WorkshopSearchPage {
        var merged: [WorkshopSearchResult] = []
        var firstBranchByID: [String: Int] = [:]
        var crossBranchDuplicates = Set<String>()
        let longest = branches.map(\.count).max() ?? 0
        for index in 0..<longest {
            for (branchIndex, branch) in branches.enumerated() where index < branch.count {
                let result = branch[index]
                if let firstBranch = firstBranchByID[result.id] {
                    if firstBranch != branchIndex { crossBranchDuplicates.insert(result.id) }
                } else {
                    firstBranchByID[result.id] = branchIndex
                    merged.append(result)
                }
            }
        }
        let page = max(1, request.page)
        let pageSize = max(1, min(request.pageSize, 30))
        let totalCount = max(0, reportedTotal - crossBranchDuplicates.count)
        let start = (page - 1) * pageSize
        let results = start < merged.count ? Array(merged[start..<min(start + pageSize, merged.count)]) : []
        return WorkshopSearchPage(
            request: request,
            totalCount: totalCount,
            totalPages: Int(ceil(Double(totalCount) / Double(pageSize))),
            results: results,
            discoveryPath: "union[\(discoveryPaths.joined(separator: ","))]"
        )
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
