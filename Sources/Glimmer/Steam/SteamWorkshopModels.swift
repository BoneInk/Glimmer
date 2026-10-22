import Foundation

/// B02 模块：Steam 创意工坊（Wallpaper Engine）数据模型。
///
/// 说明与边界：
/// - 所有公开数据来自 Steam 社区页面（`workshop/browse` 与 `sharedfiles/filedetails`）。
/// - 网页登录只代表「网页会话」，**不等于**下载权限；下载权限只由真实 SteamCMD 会话决定。
/// - 本文件不包含任何凭据类型；用户名/密码/令牌一律不进入模型。

// MARK: - 工坊作品 ID

/// 已校验的 Steam 创意工坊作品 ID（纯 ASCII 数字、非零、可用 UInt64 表示）。
struct WorkshopItemID: Hashable, Sendable, CustomStringConvertible {
    /// 规范化后的十进制字符串（无前导零）。
    let value: String
    /// 数值形式（范围校验与稳定比较用）。
    let numericValue: UInt64

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只接受 ASCII 数字：明确拒绝全角数字与其它 Unicode 数字（R08）。
        guard !trimmed.isEmpty, trimmed.count <= 20,
              trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        // 必须是正整数（拒绝 0）且不超出 UInt64。
        guard let numeric = UInt64(trimmed), numeric > 0 else { return nil }
        self.numericValue = numeric
        self.value = String(numeric)
    }

    init?(_ raw: Substring) { self.init(String(raw)) }

    var description: String { value }

    /// 规范化的公开详情页地址（所有下游请求只使用这个地址，不直接使用用户原始输入）。
    var detailsURL: URL {
        URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(value)")!
    }

    var shortURL: String { "steamcommunity.com/sharedfiles/filedetails/?id=\(value)" }
}

// MARK: - 解析用户输入

/// 用户输入的工坊地址或 ID 的解析结果。
enum WorkshopInputParse: Sendable, Equatable {
    /// 合法的作品 ID。
    case itemID(WorkshopItemID)
    /// 指向 Wallpaper Engine（appid 431960）但不是 `filedetails` 的地址（例如整个浏览页）。
    case notAnItemURL(reason: String)
    /// 指向其他 App 的工坊/社区页面。
    case wrongApp(appID: String?)
    /// 无法识别。
    case unrecognized(reason: String)

    var itemIDValue: WorkshopItemID? {
        if case .itemID(let id) = self { return id }
        return nil
    }

    var failureReason: String? {
        switch self {
        case .itemID: return nil
        case .notAnItemURL(let reason): return reason
        case .wrongApp(let appID):
            if let appID {
                return "该地址属于 AppID \(appID) 的工坊，不是 Wallpaper Engine（431960）。"
            }
            return "该地址不是 Wallpaper Engine（431960）的创意工坊页面。"
        case .unrecognized(let reason): return reason
        }
    }
}

enum WorkshopInputValidator {
    /// Wallpaper Engine 的 Steam AppID。
    static let wallpaperEngineAppID = 431_960

    /// 受信任的 Steam 域名白名单（精确匹配或「点号分隔」的子域）。
    ///
    /// 注意：不能使用裸 `hasSuffix("steamcommunity.com")`，否则
    /// `evilsteamcommunity.com`、`notsteamcommunity.com` 也会通过（R08）。
    static let trustedDomains: [String] = [
        "steamcommunity.com",
        "steampowered.com"
    ]

    static func isTrustedSteamHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return trustedDomains.contains { domain in
            lowered == domain || lowered.hasSuffix("." + domain)
        }
    }

    /// 校验用户粘贴的地址或纯数字 ID，并只返回**规范化**的作品 ID。
    ///
    /// 支持的输入形态（全部为公开 URL，不做任何登录态判断）：
    /// - `3818965540` / `  3818965540  `
    /// - `https://steamcommunity.com/sharedfiles/filedetails/?id=3818965540`
    /// - `https://steamcommunity.com/sharedfiles/filedetails/?id=3818965540&searchtext=...`
    /// - `https://steamcommunity.com/workshop/filedetails/?id=3818965540`
    /// - `steam://url/CommunityFilePage/3818965540`
    static func parse(_ raw: String) -> WorkshopInputParse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unrecognized(reason: "请输入 Steam 创意工坊链接或数字作品 ID。")
        }

        if let id = WorkshopItemID(trimmed) {
            return .itemID(id)
        }

        // steam://url/CommunityFilePage/<id>
        if trimmed.lowercased().hasPrefix("steam://") {
            let parts = trimmed.split(separator: "/")
            if let last = parts.last, let id = WorkshopItemID(last) {
                return .itemID(id)
            }
            return .unrecognized(reason: "无法从 steam:// 链接中识别作品 ID。请粘贴完整的创意工坊详情页链接。")
        }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .unrecognized(reason: "这看起来不是有效的链接或数字 ID。请粘贴 steamcommunity.com 的工坊详情页地址。")
        }

        let host = (url.host ?? "").lowercased()
        guard !host.isEmpty, isTrustedSteamHost(host) else {
            return .unrecognized(reason: "只接受 steamcommunity.com / steampowered.com 的链接，当前域名：\(host.isEmpty ? "(空)" : host)")
        }

        let path = url.path.lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        func queryValue(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name }?.value
        }

        let isFiledetails = path.contains("filedetails")
        let isBrowse = path.contains("/workshop/browse")

        // appid 校验（浏览页/其他社区页面会带 appid 参数）
        let appIDString = queryValue("appid")
        if let appIDString, let appID = Int(appIDString), appID != wallpaperEngineAppID {
            return .wrongApp(appID: appIDString)
        }

        guard isFiledetails else {
            if isBrowse {
                return .notAnItemURL(reason: "这是一个创意工坊浏览页，不是单个作品。请打开具体作品页面后复制地址，或直接粘贴作品 ID。")
            }
            return .notAnItemURL(reason: "该地址不是作品详情页（缺少 filedetails）。请粘贴形如 …/sharedfiles/filedetails/?id=数字 的链接。")
        }

        guard let idString = queryValue("id"), let id = WorkshopItemID(idString) else {
            return .notAnItemURL(reason: "详情页链接缺少有效的 id 参数（必须是正整数）。请检查链接是否完整。")
        }

        // 明确指向其他 App 的 filedetails 也拒绝（Wallpaper Engine 之外的作品无法下载）。
        if let appIDString, appIDString != String(wallpaperEngineAppID) {
            return .wrongApp(appID: appIDString)
        }

        return .itemID(id)
    }

    /// Public search defaults to Video; Web/all are explicit type selections.
    static func browseURL(
        query: String,
        sort: WorkshopSearchSort,
        page: Int,
        pageSize: Int,
        trendDays: Int = 7,
        filters: WorkshopSearchFilters = WorkshopSearchFilters()
    ) -> URL {
        var components = URLComponents(string: "https://steamcommunity.com/workshop/browse/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "appid", value: String(wallpaperEngineAppID)),
            URLQueryItem(name: "browsesort", value: sort.steamBrowseValue),
            URLQueryItem(name: "section", value: "readytouseitems")
        ]
        if let type = filters.type.requiredTag { items.append(URLQueryItem(name: "requiredtags[0]", value: type)) }
        items += [
            URLQueryItem(name: "numperpage", value: String(max(1, min(pageSize, 30)))),
            URLQueryItem(name: "p", value: String(max(1, page)))
        ]
        let tagOffset = filters.type.requiredTag == nil ? 0 : 1
        for (index, tag) in filters.requiredTags.enumerated() {
            items.append(URLQueryItem(name: "requiredtags[\(index + tagOffset)]", value: tag))
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            items.append(URLQueryItem(name: "searchtext", value: trimmedQuery))
            items.append(URLQueryItem(name: "searchtext_target", value: "0"))
        }
        if sort == .trend {
            items.append(URLQueryItem(name: "days", value: String(trendDays <= 0 ? -1 : trendDays)))
        }
        components.queryItems = items
        return components.url!
    }
}

// MARK: - 搜索排序

enum WorkshopSearchSort: String, Sendable, CaseIterable, Identifiable {
    case trend
    case mostrecent
    case toprated
    case mostsubscribed
    case lastupdated

    /// Preserve the app-facing enum while using Steam's actual public sort key.
    var steamBrowseValue: String { self == .mostsubscribed ? "totaluniquesubscribers" : rawValue }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trend: return "热门趋势"
        case .mostrecent: return "最新发布"
        case .toprated: return "最高评分"
        case .mostsubscribed: return "最多订阅"
        case .lastupdated: return "最近更新"
        }
    }

    var symbolName: String {
        switch self {
        case .trend: return "flame"
        case .mostrecent: return "clock.badge.checkmark"
        case .toprated: return "star.circle"
        case .mostsubscribed: return "person.2"
        case .lastupdated: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - 搜索条目

/// 一条工坊搜索结果（全部字段来自 Steam 实时页面）。
struct WorkshopSearchResult: Identifiable, Hashable, Sendable, Codable {
    var id: String { publishedFileID }
    var publishedFileID: String
    var title: String
    var shortDescription: String
    var consumerAppID: Int?
    var previewURL: URL?
    var timeCreated: Date?
    var timeUpdated: Date?
    var fileSizeBytes: Int64?
    /// 页面 tag（第一个通常是 `Video`/`Scene`/`Web`/`Application`）。
    var tags: [String]
    var subscriptions: Int?
    var favorited: Int?
    var views: Int?
    var commentCount: Int?
    var starRating: Double?
    var totalVotes: Int?
    var childCount: Int
    var isCollection: Bool
    var itemURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(publishedFileID)")! }

    /// 类型 tag（页面声明）。注意：这只是页面声明，下载后必须用 project.json 复核。
    var declaredTypeTag: String? {
        tags.first { ["video", "scene", "web", "application", "collection"].contains($0.lowercased()) }
    }

    var declaredKind: WorkshopItemKind { declaredTypeTag.map(WorkshopItemKind.fromTag) ?? .unknown }
    var isDeclaredVideo: Bool { declaredKind == .video }
    var isSupportedWallpaper: Bool { !isCollection && childCount == 0 && (declaredKind.isSupportedWallpaper || declaredKind == .unknown) }

    var fileSizeText: String? {
        guard let fileSizeBytes, fileSizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var createdText: String? {
        guard let timeCreated else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        return formatter.string(from: timeCreated)
    }
}

/// 一次搜索请求的参数。
struct WorkshopSearchRequest: Sendable, Equatable {
    var query: String = ""
    var sort: WorkshopSearchSort = .trend
    var page: Int = 1
    var pageSize: Int = 24
    var filters: WorkshopSearchFilters = WorkshopSearchFilters()

    var url: URL {
        WorkshopInputValidator.browseURL(query: query, sort: sort, page: page, pageSize: pageSize, trendDays: filters.trendPeriod.urlDays, filters: filters)
    }

    func specialized(for type: WorkshopSearchType, page: Int? = nil) -> WorkshopSearchRequest {
        var copy = self
        copy.filters.type = type
        if let page { copy.page = page }
        return copy
    }
}

/// 一次搜索的结果集合。
struct WorkshopSearchPage: Sendable, Equatable {
    var request: WorkshopSearchRequest
    var totalCount: Int
    var totalPages: Int?
    var results: [WorkshopSearchResult]
    /// 解析取证：命中的 SSR 查询位置（便于回归时确认页面结构是否变化）。
    var discoveryPath: String

    var hasNextPage: Bool {
        if let totalPages { return request.page < totalPages }
        return results.count >= request.pageSize
    }
}

// MARK: - 详情

/// 工坊作品的项目类型（Steam 页面 tag + project.json 的类型字段）。
enum WorkshopItemKind: String, Sendable, CaseIterable {
    case video
    case scene
    case web
    case application
    case collection
    case other
    case unknown

    var title: String {
        switch self {
        case .video: return "视频壁纸"
        case .scene: return "场景（Scene）"
        case .web: return "网页（Web）"
        case .application: return "应用程序（Application）"
        case .collection: return "合集（Collection）"
        case .other: return "其他类型"
        case .unknown: return "未知类型"
        }
    }

    var isSupportedVideo: Bool { self == .video }
    var isSupportedWallpaper: Bool { self == .video || self == .web || self == .scene }

    /// 不支持时的明确原因。
    var unsupportedReason: String? {
        switch self {
        case .video, .web, .scene: return nil
        case .application: return "这是 Application 应用程序类作品，当前不执行工坊应用程序。"
        case .collection: return "这是创意工坊合集，而不是单个作品。请展开合集后选择具体壁纸。"
        case .other: return "无法识别该作品类型。请确认链接指向 Wallpaper Engine 的视频或 Web 壁纸。"
        case .unknown: return nil // Downloaded project.json is authoritative.
        }
    }

    /// 从页面 tag（例如「Type: Video」）解析。
    static func fromTag(_ tag: String) -> WorkshopItemKind {
        switch tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video": return .video
        case "scene": return .scene
        case "web": return .web
        case "application", "app": return .application
        case "collection": return .collection
        case "": return .unknown
        default: return .other
        }
    }

    /// 从 project.json 的 `type` 字段解析。
    static func fromProjectType(_ value: String) -> WorkshopItemKind {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "video": return .video
        case "scene": return .scene
        case "web": return .web
        case "application": return .application
        case "collection", "pkg": return .collection
        default: return .other
        }
    }
}

/// Public creator identity. Requests use a canonical Steam profile, never an
/// arbitrary link from a description, comment, or imported project.
struct WorkshopAuthor: Identifiable, Hashable, Sendable {
    let profilePath: String
    let name: String
    let avatarURL: URL?
    var id: String { profilePath }
    var profileURL: URL { URL(string: "https://steamcommunity.com/" + profilePath)! }

    init?(profileURL: URL, name: String, avatarURL: URL? = nil, accountID: UInt64? = nil) {
        guard profileURL.scheme == "https", profileURL.host?.lowercased() == "steamcommunity.com",
              profileURL.user == nil, profileURL.password == nil, profileURL.port == nil,
              profileURL.query == nil, profileURL.fragment == nil else { return nil }
        let parts = profileURL.path.split(separator: "/")
        guard parts.count == 2, ["id", "profiles"].contains(parts[0]),
              !parts[1].isEmpty, parts[1].utf8.count <= 128,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              parts[1] != ".", parts[1] != ".." else { return nil }
        let base: UInt64 = 76_561_197_960_265_728
        guard accountID == nil || (accountID! > 0 && accountID! <= UInt32.max) else { return nil }
        if parts[0] == "profiles" {
            guard let value = UInt64(parts[1]), value > base, value <= base + UInt64(UInt32.max),
                  accountID == nil || value == base + accountID! else { return nil }
        }
        profilePath = accountID.map { "profiles/\(base + $0)" } ?? parts.joined(separator: "/")
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512))
        guard !self.name.isEmpty else { return nil }
        self.avatarURL = Self.imageURL(avatarURL)
    }

    static func imageURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.absoluteString.utf8.count <= 2048, let host = url.host?.lowercased(),
              ["steamstatic.com", "steamusercontent.com", "steamuserimages-a.akamaihd.net"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    func worksURL(page: Int) -> URL {
        var components = URLComponents(url: profileURL.appendingPathComponent("myworkshopfiles/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "appid", value: "431960"), URLQueryItem(name: "browsefilter", value: "myfiles"),
            URLQueryItem(name: "sortmethod", value: "creationorder"), URLQueryItem(name: "numperpage", value: "30"),
            URLQueryItem(name: "p", value: String(max(1, page))), URLQueryItem(name: "l", value: "english")]
        return components.url!
    }
}

struct WorkshopAuthorWorksPage: Sendable {
    let author: WorkshopAuthor
    let page: Int
    let totalCount: Int
    let totalPages: Int
    let results: [WorkshopSearchResult]
}

/// 工坊作品详情（来自公开详情页）。
struct WorkshopItemDetail: Identifiable, Hashable, Sendable {
    var id: String { publishedFileID }
    var publishedFileID: String
    var title: String
    var description: String
    var appID: Int?
    var kind: WorkshopItemKind
    /// 页面声明的原始类型标签（如 `Video`）。
    var declaredTypeTag: String?
    var previewImageURL: URL?
    var tags: [(key: String, value: String)]
    var subscriptions: Int?
    var favorited: Int?
    var views: Int?
    var timeCreated: Date?
    var timeUpdated: Date?
    /// 解析取证：哪些字段真实出现（供回归诊断）。
    var diagnostics: [String]
    var authors: [WorkshopAuthor] = []
    var fileSizeText: String? = nil
    var createdText: String? = nil
    var updatedText: String? = nil

    static func == (lhs: WorkshopItemDetail, rhs: WorkshopItemDetail) -> Bool {
        lhs.publishedFileID == rhs.publishedFileID
            && lhs.title == rhs.title
            && lhs.description == rhs.description
            && lhs.kind == rhs.kind
            && lhs.tags.map(\.value) == rhs.tags.map(\.value)
            && lhs.authors == rhs.authors
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(publishedFileID)
        hasher.combine(kind)
    }

    var unsupportedReason: String? { kind.unsupportedReason }

    var isSupportedVideo: Bool { kind.isSupportedVideo }
    var isSupportedWallpaper: Bool { kind.isSupportedWallpaper || kind == .unknown }

    var itemURL: URL { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(publishedFileID)")! }

    func tagValue(_ key: String) -> String? {
        tags.first { $0.key.lowercased() == key.lowercased() }?.value
    }

    var genreText: String? { tagValue("Genre") ?? tagValue("类型") }
    var resolutionText: String? { tagValue("Resolution") ?? tagValue("分辨率") }
    var ageRatingText: String? { tagValue("Age Rating") ?? tagValue("年龄分级") }

    var searchResult: WorkshopSearchResult {
        var values = tags.map(\.value)
        if let declaredTypeTag, !values.contains(declaredTypeTag) { values.insert(declaredTypeTag, at: 0) }
        return .init(publishedFileID: publishedFileID, title: title, shortDescription: description,
            consumerAppID: appID, previewURL: previewImageURL, timeCreated: timeCreated, timeUpdated: timeUpdated,
            tags: values, subscriptions: subscriptions, favorited: favorited, views: views,
            childCount: 0, isCollection: kind == .collection)
    }
}

// MARK: - 下载导入元数据（对外回调载荷）

/// 下载并校验完成后，交给主 App（ImportService）的元数据。
///
/// 该类型刻意不引用 B01 正在演进的任何模型，便于主控后续接线。
struct WorkshopMetadata: Hashable, Sendable, Codable {
    var publishedFileID: String
    var title: String
    var projectType: String
    var descriptionExcerpt: String?
    var previewImageURLString: String?
    var authorSteamID: String?
    var fileSizeBytes: Int64?
    var timeCreated: Date?
    var declaredTags: [String]
    var projectDirectoryPath: String
    var videoRelativePath: String?
    var videoByteSize: Int64?
    var projectJSONRelativePath: String? = nil
    var entryRelativePath: String? = nil
    var projectByteSize: Int64? = nil
    var projectFingerprint: String? = nil

    var projectDirectoryURL: URL { URL(fileURLWithPath: projectDirectoryPath, isDirectory: true) }
    var workshopURLString: String {
        "https://steamcommunity.com/sharedfiles/filedetails/?id=\(publishedFileID)"
    }
}

// MARK: - 日志（不记录账号名/凭据）

/// 模块内统一日志。SteamCMD 原始输出不落盘，这里只记录脱敏后的短状态。
enum WorkshopLog {
    static func info(_ message: String) {
        #if DEBUG
        NSLog("[Workshop] %@", sanitize(message))
        #endif
    }

    static func notice(_ message: String) {
        NSLog("[Workshop] %@", sanitize(message))
    }

    /// 脱敏：截断长度并去掉可能泄露账号的 `username` 字段。
    static func sanitize(_ message: String) -> String {
        var text = message
        if let range = text.range(of: "username\\s+[^\\s]+", options: [.regularExpression, .caseInsensitive]) {
            text.replaceSubrange(range, with: "username <已隐藏>")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > 300 {
            text = String(text.prefix(300)) + "…"
        }
        return text
    }

    static func timestamp() -> String {
        Date().formatted(.iso8601)
    }
}

/// A preview of an already validated, completed local video; never a remote thumbnail.
struct WorkshopLocalVideoPreview: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var fileURL: URL
}

enum WorkshopQueueMoveDirection: Sendable {
    case up
    case down
}

/// 只有用户点击「设为壁纸」时才提交的目标。
enum WorkshopWallpaperTarget: String, CaseIterable, Identifiable, Sendable {
    case currentDisplay
    case allDisplays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .currentDisplay: return "当前显示器"
        case .allDisplays: return "全部显示器"
        }
    }
}

enum WorkshopWallpaperApplyResult: Equatable, Sendable {
    case applied(String)
    case failed(String)
    var message: String {
        switch self { case .applied(let value), .failed(let value): return value }
    }
    var succeeded: Bool {
        if case .applied = self { return true }
        return false
    }
}
