import Foundation

struct WorkshopItem: Identifiable, Codable {
    let id: String
    let title: String
    let previewURL: String?
    let tags: [String]
    let subscriptions: Int
    let fileSize: Int
    let creatorAppId: Int?
    let creatorId: String?
    let description: String?
    let votesUp: Int
    let votesDown: Int
    /// The item's key/value tags (QueryFiles `kvtags`), e.g. the Workshop EULA version that
    /// allows the mobile app. Nil for items stored before these were read.
    var kvTags: [String: String]? = nil
    /// Steam's `time_updated` (Unix seconds): when the item last changed. Nil for items stored
    /// before it was read.
    var timeUpdated: Int? = nil
    /// The items this one requires (QueryFiles `children`): a preset's base wallpaper, or the
    /// assets a wallpaper borrows. Nil when the response didn't list them.
    var dependencyIds: [String]? = nil

    /// A Workshop preset item (the `Preset` category tag) rather than a wallpaper.
    var isPreset: Bool {
        tags.contains { $0.caseInsensitiveCompare("Preset") == .orderedSame }
    }

    var previewImageURL: URL? {
        guard let urlString = previewURL else { return nil }
        return URL(string: urlString)
    }
}

final class WorkshopMetadataStore {
    static let shared = WorkshopMetadataStore()

    private let storageKey = "WorkshopMetadataById"
    private var metadata: [String: WorkshopItem]
    private let lock = NSLock()

    private init() {
        guard let data = Self.storedData(forKey: storageKey),
              let saved = OWELog.attempt(.workshop, "Stored Workshop metadata", { try JSONDecoder().decode([String: WorkshopItem].self, from: data) }) else {
            metadata = [:]
            return
        }
        metadata = saved
    }

    func item(for workshopId: String) -> WorkshopItem? {
        lock.lock()
        defer { lock.unlock() }
        return metadata[workshopId]
    }

    func save(_ item: WorkshopItem) {
        save([item])
    }

    /// Saves a response's items with one write. The store holds thousands of items, so encoding
    /// it once per item made every QueryFiles page take seconds.
    func save(_ items: [WorkshopItem]) {
        guard !items.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for item in items {
            metadata[item.id] = item
        }
        if let data = OWELog.attempt(.workshop, "Saving Workshop metadata", { try JSONEncoder().encode(metadata) }) {
            UserDefaults.app.set(data, forKey: storageKey)
        }
    }

    private static func storedData(forKey key: String) -> Data? {
        if let data = UserDefaults.app.data(forKey: key) { return data }
        return UserDefaults.app.string(forKey: key)?.data(using: .utf8)
    }
}

final class SteamPlayerStore {
    static let shared = SteamPlayerStore()

    private let storageKey = "SteamPlayersById"
    private var players: [String: SteamPlayer]
    private let lock = NSLock()

    private init() {
        guard let data = Self.storedData(forKey: storageKey),
              let saved = OWELog.attempt(.workshop, "Stored Steam players", { try JSONDecoder().decode([String: SteamPlayer].self, from: data) }) else {
            players = [:]
            return
        }
        players = saved
    }

    func player(for steamId: String) -> SteamPlayer? {
        lock.lock()
        defer { lock.unlock() }
        return players[steamId]
    }

    func save(_ player: SteamPlayer) {
        lock.lock()
        defer { lock.unlock() }
        players[player.steamId] = player
        if let data = OWELog.attempt(.workshop, "Saving Steam players", { try JSONEncoder().encode(players) }) {
            UserDefaults.app.set(data, forKey: storageKey)
        }
    }

    private static func storedData(forKey key: String) -> Data? {
        if let data = UserDefaults.app.data(forKey: key) { return data }
        return UserDefaults.app.string(forKey: key)?.data(using: .utf8)
    }
}

struct SteamPlayer: Codable, Equatable {
    let steamId: String
    let personaName: String
    let avatarURL: URL?

    enum CodingKeys: String, CodingKey {
        case steamId = "steamid"
        case personaName = "personaname"
        case avatarURL = "avatarfull"
    }
}

/// The Workshop tab's sorts: WE's own list (`sortOptions` in `ui/dist/scripts/scripts.js`), its
/// `querytype` values as raw values, in WE's order. Each is a QueryFiles `query_type`
/// (`EPublishedFileQueryType`), WE's "Most Popular" lists Steam's RankedByTrend over a number of
/// days. The Discover lists use the same sorts.
///
/// WE's other sorts (My Favorites, Voted Up, Friends' Favorites, Created By Friends, Created By
/// Followed Users) are lists of the signed-in Steam account, which WE reads through the Steam
/// client; they aren't here.
enum WorkshopSortOrder: String, CaseIterable, Identifiable {
    case topRated = "top_rated"
    case trendYear = "trend_year"
    case trendMonth = "trend_month"
    case trendWeek = "trend_week"
    case trendToday = "trend_today"
    case mostRecent = "most_recent"
    case mostUpVotes = "most_up_votes"
    case subscriptions

    /// WE's default sort for the Workshop tab.
    static let `default` = WorkshopSortOrder.trendYear

    var id: String { rawValue }

    var displayName: LocalizedStringResource {
        switch self {
        case .topRated: return LocalizedStringResource("Top Rated", comment: "Workshop sort order")
        case .trendYear: return LocalizedStringResource("Most Popular (Year)", comment: "Workshop sort order: most popular over the last year")
        case .trendMonth: return LocalizedStringResource("Most Popular (Month)", comment: "Workshop sort order: most popular over the last month")
        case .trendWeek: return LocalizedStringResource("Most Popular (Week)", comment: "Discover list: the week's most popular wallpapers")
        case .trendToday: return LocalizedStringResource("Most Popular (Today)", comment: "Workshop sort order: most popular today")
        case .mostRecent: return LocalizedStringResource("Most Recent", comment: "Workshop sort order")
        case .mostUpVotes: return LocalizedStringResource("Most Up Votes", comment: "Workshop sort order: most votes up")
        case .subscriptions: return LocalizedStringResource("Most Subscriptions", comment: "Workshop sort order")
        }
    }

    /// `EPublishedFileQueryType`.
    var queryType: Int {
        switch self {
        case .topRated: return 0                                          // RankedByVote
        case .trendYear, .trendMonth, .trendWeek, .trendToday: return 3   // RankedByTrend
        case .mostRecent: return 1                                        // RankedByPublicationDate
        case .mostUpVotes: return 11                                      // RankedByVotesUp
        case .subscriptions: return 9                                     // RankedByTotalUniqueSubscriptions
        }
    }

    /// QueryFiles `days`: the window RankedByTrend counts votes in.
    var trendDays: Int? {
        switch self {
        case .trendToday: return 1
        case .trendWeek: return 7
        case .trendMonth: return 30
        case .trendYear: return 365
        case .topRated, .mostRecent, .mostUpVotes, .subscriptions: return nil
        }
    }

    /// When search_text is provided, Steam requires query_type=12 (RankedByTextSearch)
    func queryTypeForSearch(hasText: Bool) -> Int {
        hasText ? 12 : queryType
    }
}

class WorkshopAPIService {
    static let wallpaperEngineAppId = 431960
    /// Steam reads the Web API key from this header, which keeps it out of request URLs.
    static let apiKeyHeader = "x-webapi-key"
    private static let queryFilesURL = URL(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!

    private let apiKey: KeychainSecret
    private let session: URLSession

    init(apiKey: KeychainSecret = SteamCredentials.webAPIKey(), session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    /// Browse and search need a Steam Web API key (IPublishedFileService/QueryFiles).
    /// GetPublishedFileDetails doesn't. `filter` gives the tags; what it leaves to the results
    /// (`WorkshopQuery.clientShowOnly`) is the caller's to check.
    func searchItems(
        query: String = "",
        filter: WorkshopQuery = WorkshopQuery(),
        sortOrder: WorkshopSortOrder = .default,
        page: Int = 1,
        perPage: Int = 20
    ) async throws -> [WorkshopItem] {
        try await queryFiles(Self.queryItems(text: query, filter: filter, sortOrder: sortOrder,
                                             page: page, perPage: perPage))
    }

    /// QueryFiles' parameters for a search: `requiredtags[n]` with `match_all_tags`, and
    /// `excludedtags[n]`, as `WorkshopQuery` plans them, and the sort's `days` (a text search is
    /// ranked by relevance, so it has none).
    static func queryItems(text: String, filter: WorkshopQuery, sortOrder: WorkshopSortOrder,
                           page: Int, perPage: Int) -> [URLQueryItem] {
        var items = queryItems(queryType: sortOrder.queryTypeForSearch(hasText: !text.isEmpty), text: text,
                               filter: filter, page: page, perPage: perPage)
        if text.isEmpty, let days = sortOrder.trendDays {
            items.append(URLQueryItem(name: "days", value: "\(days)"))
        }
        return items
    }

    /// QueryFiles' parameters for `queryType` (`EPublishedFileQueryType`) and `filter`'s tags.
    static func queryItems(queryType: Int, text: String = "", filter: WorkshopQuery,
                           page: Int, perPage: Int) -> [URLQueryItem] {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "query_type", value: "\(queryType)"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "numperpage", value: "\(perPage)"),
            URLQueryItem(name: "appid", value: "\(wallpaperEngineAppId)"),
            URLQueryItem(name: "match_all_tags", value: filter.matchAllTags ? "true" : "false"),
            URLQueryItem(name: "return_tags", value: "true"),
            URLQueryItem(name: "return_kv_tags", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "return_short_description", value: "true"),
            URLQueryItem(name: "return_details", value: "true"),
            URLQueryItem(name: "return_children", value: "true"),
        ]
        if !text.isEmpty {
            queryItems.append(URLQueryItem(name: "search_text", value: text))
        }
        for (index, tag) in filter.requiredTags.enumerated() {
            queryItems.append(URLQueryItem(name: "requiredtags[\(index)]", value: tag))
        }
        for (index, tag) in filter.excludedTags.enumerated() {
            queryItems.append(URLQueryItem(name: "excludedtags[\(index)]", value: tag))
        }
        if let parent = filter.childOf {
            queryItems.append(URLQueryItem(name: "child_publishedfileid", value: parent))
        }
        return queryItems
    }

    /// One page of a Discover section (QueryFiles with the user's Web API key).
    func discoverItems(_ section: WorkshopDiscoverSection, page: Int, perPage: Int) async throws -> [WorkshopItem] {
        try await queryFiles(WorkshopDiscover.queryItems(for: section, page: page, perPage: perPage))
    }

    /// A QueryFiles request with the user's Web API key; the items are remembered for the library.
    private func queryFiles(_ queryItems: [URLQueryItem]) async throws -> [WorkshopItem] {
        guard let key = apiKey.load() else { throw WorkshopAPIError.noAPIKey }
        var components = URLComponents(url: Self.queryFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let url = components.url else { throw WorkshopAPIError.invalidURL }
        let items = try Self.parseItems(from: try await sendKeyed(url, key: key))
        WorkshopMetadataStore.shared.save(items)
        return items
    }

    /// Get details for specific workshop items by their IDs.
    func getItemDetails(workshopIds: [String]) async throws -> [WorkshopItem] {
        guard let body = Self.itemDetailsBody(workshopIds: workshopIds) else { return [] }
        let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, httpResponse) = try await send(request)
        guard httpResponse.statusCode == 200 else { throw WorkshopAPIError.httpError(httpResponse.statusCode) }

        let items = try Self.parseItems(from: data)
        WorkshopMetadataStore.shared.save(items)
        return items
    }

    /// The form body of GetPublishedFileDetails for the Workshop ids among `workshopIds` (ASCII
    /// digits; anything else, e.g. a hand-edited project.json `workshopid`, is left out), percent
    /// encoded; nil when none is an id.
    static func itemDetailsBody(workshopIds: [String]) -> Data? {
        let ids = workshopIds.filter(WorkshopCollection.isID)
        if ids.count < workshopIds.count {
            OWELog.debug(.workshop, "Left \(workshopIds.count - ids.count) invalid Workshop ids out of a details request")
        }
        guard !ids.isEmpty else { return nil }
        let fields = [
            ("itemcount", String(ids.count)),
            ("includetags", "true"),
            ("includevotes", "true"),
            ("includeshortdescription", "true"),
        ] + ids.enumerated().map { ("publishedfileids[\($0.offset)]", $0.element) }
        // Form encoding: everything but unreserved characters, so "&", "=" and "+" can't split a field.
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let body = fields.map { name, value in
            [name, value].map { $0.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }.joined(separator: "=")
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// The items of a public Workshop collection, in its order (keyless: GetCollectionDetails,
    /// then GetPublishedFileDetails in batches). Nested collections are left out.
    func getCollection(id collectionID: String) async throws -> (title: String?, items: [WorkshopItem]) {
        var request = URLRequest(url: WorkshopCollection.detailsURL)
        request.httpMethod = "POST"
        request.httpBody = WorkshopCollection.detailsBody(collectionID: collectionID)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw WorkshopAPIError.httpError(response.statusCode) }
        guard let children = try WorkshopCollection.children(of: collectionID, in: data) else {
            throw WorkshopCollection.Failure.notFound(collectionID)
        }
        let ids = children.filter { $0.type != .collection }.map(\.id)
        let title = try await getItemDetails(workshopIds: [collectionID]).first?.title
        return (title, try await getItemDetails(inBatches: ids))
    }

    /// GetPublishedFileDetails for any number of ids, in Steam's batch size, in the ids' order.
    func getItemDetails(inBatches ids: [String]) async throws -> [WorkshopItem] {
        var items: [String: WorkshopItem] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + WorkshopCollection.detailsBatchSize, ids.count)])
            for item in try await getItemDetails(workshopIds: batch) { items[item.id] = item }
            start += WorkshopCollection.detailsBatchSize
        }
        return ids.compactMap { items[$0] }
    }

    /// Whether each of `ids` can still be downloaded (keyless GetPublishedFileDetails, in Steam's
    /// batch size). Ids the response leaves out are missing from the result.
    func availability(of ids: [String]) async throws -> [String: WorkshopItemAvailability] {
        var result: [String: WorkshopItemAvailability] = [:]
        var start = 0
        while start < ids.count {
            let batch = Array(ids[start..<min(start + WorkshopCollection.detailsBatchSize, ids.count)])
            var request = URLRequest(url: WorkshopItemAvailability.detailsURL)
            request.httpMethod = "POST"
            request.httpBody = WorkshopItemAvailability.detailsBody(ids: batch)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else { throw WorkshopAPIError.httpError(response.statusCode) }
            result.merge(try WorkshopItemAvailability.parse(data)) { _, new in new }
            start += WorkshopCollection.detailsBatchSize
        }
        return result
    }

    /// The account's subscribed Wallpaper Engine items (GetUserFiles `type=mysubscriptions`, with
    /// the user's Web API key). An account with none, or a private one, answers `.empty`.
    func getSubscribedItemIDs(steamID: String) async throws -> WorkshopSubscriptions.Outcome {
        try await getUserFileIDs(steamID: steamID, list: .subscriptions)
    }

    /// The account's favourited Wallpaper Engine items (GetUserFiles `type=myfavorites`, with the
    /// user's Web API key): Wallpaper Engine's own favourites, which live in the Steam account.
    func getFavoritedItemIDs(steamID: String) async throws -> WorkshopSubscriptions.Outcome {
        try await getUserFileIDs(steamID: steamID, list: .favorites)
    }

    private func getUserFileIDs(steamID: String,
                                list: WorkshopSubscriptions.List) async throws -> WorkshopSubscriptions.Outcome {
        guard WorkshopSubscriptions.isSteamID64(steamID) else { throw WorkshopAPIError.invalidURL }
        guard let key = apiKey.load() else { throw WorkshopAPIError.noAPIKey }
        var ids: [String] = []
        // Up to 50 pages of 100; Steam stops returning files past the last one.
        for page in 1...50 {
            var components = URLComponents(url: WorkshopSubscriptions.userFilesURL, resolvingAgainstBaseURL: false)!
            components.queryItems = WorkshopSubscriptions.queryItems(steamID: steamID, page: page, list: list)
            guard let url = components.url else { throw WorkshopAPIError.invalidURL }
            guard case .items(let found) = try WorkshopSubscriptions.outcome(from: try await sendKeyed(url, key: key)) else { break }
            let new = found.filter { !ids.contains($0) }
            ids += new
            if found.count < 100 || new.isEmpty { break }
        }
        return ids.isEmpty ? .empty : .items(ids)
    }

    func getAuthorWorkshopItems(steamId: String) async throws -> [WorkshopItem] {
        var components = URLComponents(string: "https://steamcommunity.com/profiles/\(steamId)/myworkshopfiles/")!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "\(Self.wallpaperEngineAppId)"),
            URLQueryItem(name: "numperpage", value: "30")
        ]
        guard let url = components.url else { throw WorkshopAPIError.invalidURL }
        let (data, httpResponse) = try await send(URLRequest(url: url))
        guard httpResponse.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw WorkshopAPIError.requestFailed
        }
        let pattern = #"sharedfiles/filedetails/\?id=(\d+)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var ids: [String] = []
        for match in regex.matches(in: html, range: range) {
            guard let idRange = Range(match.range(at: 1), in: html) else { continue }
            let id = String(html[idRange])
            if !ids.contains(id) { ids.append(id) }
        }
        return try await getItemDetails(workshopIds: ids)
    }

    /// The author's persona name and avatar, cached in `SteamPlayerStore`. Uses
    /// `GetPlayerSummaries` with a key, else the keyless community profile XML.
    func getPlayerSummary(steamId: String) async throws -> SteamPlayer? {
        guard steamId.allSatisfy(\.isNumber) else { throw WorkshopAPIError.invalidURL }
        let player: SteamPlayer?
        if let key = apiKey.load() {
            var components = URLComponents(string: "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/")!
            components.queryItems = [URLQueryItem(name: "steamids", value: steamId)]
            guard let url = components.url else { throw WorkshopAPIError.invalidURL }
            let data = try await sendKeyed(url, key: key)

            struct PlayerResponse: Decodable {
                struct Response: Decodable { let players: [SteamPlayer] }
                let response: Response
            }
            player = try JSONDecoder().decode(PlayerResponse.self, from: data).response.players.first
        } else {
            player = try await getCommunityProfile(steamId: steamId)
        }
        if let player {
            SteamPlayerStore.shared.save(player)
        }
        return player
    }

    private func getCommunityProfile(steamId: String) async throws -> SteamPlayer? {
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(steamId)?xml=1") else {
            throw WorkshopAPIError.invalidURL
        }
        let (data, response) = try await send(URLRequest(url: url))
        guard response.statusCode == 200 else { throw WorkshopAPIError.httpError(response.statusCode) }
        return SteamProfileXMLParser.player(from: data, steamId: steamId)
    }

    /// Checks `key` with the cheapest call that needs it: one QueryFiles result.
    func validate(apiKey key: String) async throws {
        var components = URLComponents(url: Self.queryFilesURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "appid", value: "\(Self.wallpaperEngineAppId)"),
            URLQueryItem(name: "numperpage", value: "1"),
        ]
        guard let url = components.url else { throw WorkshopAPIError.invalidURL }
        _ = try await sendKeyed(url, key: key)
    }

    // MARK: - Requests

    /// A GET with the Web API key in the `x-webapi-key` header, never in the URL.
    private func sendKeyed(_ url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: Self.apiKeyHeader)
        let (data, response) = try await send(request, secrets: [key])
        switch response.statusCode {
        case 200: return data
        case 401, 403: throw WorkshopAPIError.invalidAPIKey
        default: throw WorkshopAPIError.httpError(response.statusCode)
        }
    }

    /// Transport errors are logged once, redacted, and surfaced as `requestFailed`.
    private func send(_ request: URLRequest, secrets: [String] = []) async throws -> (Data, HTTPURLResponse) {
        let endpoint = request.url.map { "\($0.host ?? "")\($0.path)" } ?? "<no url>"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw WorkshopAPIError.requestFailed }
            if http.statusCode != 200 {
                OWELog.error(.workshop, "Steam request \(endpoint) returned HTTP \(http.statusCode)")
            }
            return (data, http)
        } catch let error as WorkshopAPIError {
            throw error
        } catch {
            OWELog.error(.workshop, SteamSecretRedactor.redact("Steam request \(endpoint) failed: \(error)", secrets: secrets))
            throw WorkshopAPIError.requestFailed
        }
    }

    // MARK: - Response Parsing

    /// The items in a QueryFiles or GetPublishedFileDetails response.
    static func parseItems(from data: Data) throws -> [WorkshopItem] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? [String: Any]
        else {
            // A Steam error page or another shape isn't "no results".
            throw WorkshopAPIError.unexpectedResponse
        }
        // A query with no results has a response without files.
        guard let files = response["publishedfiledetails"] as? [[String: Any]] else { return [] }

        return files.compactMap { parseFileDict($0) }
    }

    private static func parseFileDict(_ dict: [String: Any]) -> WorkshopItem? {
        guard let publishedFileId = dict["publishedfileid"] as? String,
              let title = dict["title"] as? String
        else { return nil }

        let previewURL = dict["preview_url"] as? String
        let tags = parseTags(from: dict["tags"])
        let subscriptions = dict["subscriptions"] as? Int ?? dict["lifetime_subscriptions"] as? Int ?? 0
        let fileSize = int64(dict["file_size"]) ?? 0
        let creatorAppId = dict["creator_app_id"] as? Int
        let creatorId = dict["creator"] as? String
        let description = dict["short_description"] as? String ?? dict["description"] as? String
        let votesUp = dict["votes_up"] as? Int ?? 0
        let votesDown = dict["votes_down"] as? Int ?? 0

        return WorkshopItem(
            id: publishedFileId,
            title: title,
            previewURL: previewURL,
            tags: tags,
            subscriptions: subscriptions,
            fileSize: fileSize,
            creatorAppId: creatorAppId,
            creatorId: creatorId,
            description: description,
            votesUp: votesUp,
            votesDown: votesDown,
            kvTags: parseKVTags(from: dict["kvtags"]),
            timeUpdated: dict["time_updated"] as? Int,
            dependencyIds: parseChildren(from: dict["children"])
        )
    }

    /// A number Steam sends either as a JSON number or, for 64-bit fields such as `file_size`, as
    /// a numeric string.
    static func int64(_ value: Any?) -> Int? {
        if let text = value as? String { return Int(text) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    /// `children` as `[{"publishedfileid": …, "sortorder": …, "file_type": …}]`; nil when absent.
    private static func parseChildren(from value: Any?) -> [String]? {
        guard let children = value as? [[String: Any]] else { return nil }
        return children.compactMap { child in
            let id = (child["publishedfileid"] as? String) ?? (child["publishedfileid"] as? NSNumber)?.stringValue
            return id.flatMap { WorkshopCollection.isID($0) ? $0 : nil }
        }
    }

    /// `kvtags` as `[{"key": …, "value": …}]`; nil when the response has none.
    private static func parseKVTags(from value: Any?) -> [String: String]? {
        guard let pairs = value as? [[String: Any]] else { return nil }
        var tags: [String: String] = [:]
        for pair in pairs {
            guard let key = pair["key"] as? String, let value = pair["value"] as? String else { continue }
            tags[key] = value
        }
        return tags
    }

    private static func parseTags(from value: Any?) -> [String] {
        let rawTags: [String]
        if let tagObjects = value as? [[String: Any]] {
            rawTags = tagObjects.compactMap { $0["tag"] as? String }
        } else if let tagStrings = value as? [String] {
            rawTags = tagStrings
        } else {
            rawTags = []
        }

        return Array(Set(rawTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

enum WorkshopAPIError: LocalizedError {
    case invalidURL
    case requestFailed
    case noAPIKey
    case invalidAPIKey
    case httpError(Int)
    /// The answer isn't the shape Steam's API answers with.
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "Invalid API URL")
        case .requestFailed: return String(localized: "API request failed — check your network connection")
        case .noAPIKey: return String(localized: "Steam Web API key required.\nGet a free key at steamcommunity.com/dev/apikey\nthen enter it below.")
        case .invalidAPIKey: return String(localized: "Invalid API key.\nGet a valid key at steamcommunity.com/dev/apikey")
        case .httpError(let code): return String(localized: "Steam API returned HTTP \(code)", comment: "%lld is an HTTP status code")
        case .unexpectedResponse: return String(localized: "Steam API returned an unexpected response.",
                                                comment: "Workshop error when Steam's answer can't be read")
        }
    }
}
