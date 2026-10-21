import Foundation

/// Steam 作品详情页（`sharedfiles/filedetails`）解析。
///
/// 实测（2026-10-17）：详情页**没有** `script#valve-ssr-data`，仍使用传统 HTML：
/// - 标题：`div.workshopItemTitle`（`id="workshopItemTitle"` 的另一种写法）
/// - 描述：`div.workshopItemDescription`（多语言版本会显示「描述」标题 + 正文 div）
/// - 类型与标签：`div.workshopTags` 内的 `span.workshopTagsTitle` + `<a>`（例如「Type: Video」）
/// - 合集：页面出现 `SubscribeCollection` / `collectionItem` 等标记
/// 因此这里对传统结构做解析，并在结构变化时给出明确错误而不是空结果。
enum WorkshopItemPageParser {
    static func parse(html: String, requestedID: String) throws -> WorkshopItemDetail {
        var diagnostics: [String] = []

        // 1) 标题
        let title = extractTitle(from: html)
        if title == nil { diagnostics.append("未找到 workshopItemTitle 元素") }

        // 2) 标签（Type / Genre / Resolution / Age Rating …）
        let tagPairs = SteamHTML.workshopTagPairs(in: html)
        if tagPairs.isEmpty { diagnostics.append("未找到 workshopTags 标签块") }

        // 3) 类型：优先「Type: X」标签
        let typeTag = tagPairs.first { $0.key.lowercased() == "type" }?.value
        var kind: WorkshopItemKind = typeTag.map(WorkshopItemKind.fromTag) ?? .unknown
        if typeTag == nil { diagnostics.append("标签中没有 Type 字段") }

        // 4) 合集判定（合集页类型标签为 Collection，且存在订阅合集按钮）
        let isCollection = kind == .collection
            || html.contains("SubscribeCollection")
            || html.contains("collectionItem")
            || html.contains("id=\"collectionItem")
        if isCollection {
            kind = .collection
            diagnostics.append("页面包含合集标记")
        }

        // 5) AppID：从页面内容区提取（排除社区页脚等噪声，取 filedetails / 作品区块内的 appid）
        let appID = extractConsumerAppID(from: html)
        if appID == nil { diagnostics.append("未提取到 consumer appid") }

        // 6) 描述：优先 workshopItemDescription 后的正文
        let description = extractDescription(from: html)
        if description == nil { diagnostics.append("未找到描述正文") }

        // 7) 预览图
        let preview = extractPreviewURL(from: html)

        // 8) 统计
        let stats = extractStats(from: html)

        // 9) 时间
        let timeCreated = extractDate(from: html, marker: "timeCreated")
        let timeUpdated = extractDate(from: html, marker: "timeUpdated")

        guard title != nil else {
            throw SteamHTTPError.structureChanged("详情页中没有解析到标题（Steam 结构可能变化，或该作品不存在/被删除）")
        }

        return WorkshopItemDetail(
            publishedFileID: requestedID,
            title: title ?? "(无标题)",
            description: description ?? "",
            appID: appID,
            kind: kind,
            declaredTypeTag: typeTag,
            previewImageURL: preview,
            tags: tagPairs,
            subscriptions: stats.subscriptions,
            favorited: stats.favorited,
            views: stats.views,
            timeCreated: timeCreated,
            timeUpdated: timeUpdated,
            diagnostics: diagnostics
        )
    }

    // MARK: - 字段抽取

    static func extractTitle(from html: String) -> String? {
        // 兼容 id="workshopItemTitle" 与 class="workshopItemTitle"
        if let raw = SteamHTML.elementByIDContent(in: html, elementID: "workshopItemTitle", limit: 4_000) {
            let text = SteamHTML.collapseWhitespace(SteamHTML.stripTags(raw))
            if !text.isEmpty { return text }
        }
        if let raw = SteamHTML.elementContent(in: html, className: "workshopItemTitle", tagLimit: 4_000) {
            if let closing = raw.range(of: "</div>") {
                let text = SteamHTML.collapseWhitespace(SteamHTML.stripTags(String(raw[raw.startIndex..<closing.lowerBound])))
                if !text.isEmpty { return text }
            }
        }
        // 最后兜底：<title> 标签
        if let raw = SteamHTML.firstMatch(in: html, pattern: "<title>(.{1,300}?)</title>") {
            let text = SteamHTML.collapseWhitespace(SteamHTML.stripTags(raw))
            let cleaned = text.replacingOccurrences(of: "Steam 创意工坊 :: ", with: "")
                .replacingOccurrences(of: " :: Steam 创意工坊", with: "")
                .replacingOccurrences(of: "Steam Workshop :: ", with: "")
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    static func extractDescription(from html: String) -> String? {
        // 详情页描述正文位于 workshopItemDescription 之后的 div（多语言为「描述」标题 + 正文）。
        if let raw = SteamHTML.elementContent(in: html, className: "workshopItemDescription", tagLimit: 60_000) {
            var text = raw
            if let bodyStart = raw.range(of: "<div[^>]*>", options: .regularExpression),
               let bodyEnd = raw.range(of: "</div>", options: .backwards),
               bodyStart.upperBound < bodyEnd.lowerBound {
                text = String(raw[bodyStart.upperBound..<bodyEnd.lowerBound])
            } else if let closing = raw.range(of: "</div>") {
                text = String(raw[raw.startIndex..<closing.lowerBound])
            }
            let cleaned = SteamHTML.collapseWhitespace(SteamHTML.stripTags(text))
            if !cleaned.isEmpty { return cleaned }
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "id=\"workshopItemDescription\"[^>]*>(.{0,60000}?)</div>", group: 1) {
            let cleaned = SteamHTML.collapseWhitespace(SteamHTML.stripTags(raw))
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    static func extractConsumerAppID(from html: String) -> Int? {
        // 详情页把作品所属 App 放在 apphub 区块；取「内容与讨论」区域内的第一个 appid。
        if let raw = SteamHTML.firstMatch(in: html, pattern: "apphub_AppName[^>]*>(?:<[^>]*>)*([^<]{0,80})<", group: 1) {
            _ = SteamHTML.collapseWhitespace(raw) // 应用名仅用于诊断
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "app_workshop_instructions.{0,4000}?appid=(\\d+)", group: 1),
           let value = Int(raw) {
            return value
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "\"appid\"\\s*:\\s*(\\d+)", group: 1), let value = Int(raw) {
            return value
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "store.steampowered.com/app/(\\d+)", group: 1), let value = Int(raw) {
            return value
        }
        // 兜底：详情页里的第一个 appid= 参数（社区页脚同样存在，但通常同为一个 App）。
        if let raw = SteamHTML.firstMatch(in: html, pattern: "appid=(\\d+)", group: 1), let value = Int(raw) {
            return value
        }
        return nil
    }

    static func extractPreviewURL(from html: String) -> URL? {
        guard let raw = SteamHTML.firstMatch(in: html, pattern: "(https://images\\.steamusercontent\\.com/ugc/[0-9A-Fa-f/]+?/)", group: 1) else {
            return nil
        }
        return URL(string: raw)
    }

    private static func extractStats(from html: String) -> (subscriptions: Int?, favorited: Int?, views: Int?) {
        var subscriptions: Int?
        var favorited: Int?
        var views: Int?

        if let raw = SteamHTML.firstMatch(in: html, pattern: "(\\d[\\d,]*)\\s*</td>\\s*<td>\\s*(?:当前订阅者|Current Subscribers)", group: 1) {
            subscriptions = Int(raw.replacingOccurrences(of: ",", with: ""))
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "(\\d[\\d,]*)\\s*</td>\\s*<td>\\s*(?:当前收藏人数|Current Favorites?|Favorited)", group: 1) {
            favorited = Int(raw.replacingOccurrences(of: ",", with: ""))
        }
        if let raw = SteamHTML.firstMatch(in: html, pattern: "(\\d[\\d,]*)\\s*</td>\\s*<td>\\s*(?:不重复访客数|Unique Visitors)", group: 1) {
            views = Int(raw.replacingOccurrences(of: ",", with: ""))
        }
        if subscriptions == nil,
           let raw = SteamHTML.firstMatch(in: html, pattern: "(\\d[\\d,]*)\\s*</td>\\s*<td>\\s*(?:订阅者|Subscribers)", group: 1) {
            subscriptions = Int(raw.replacingOccurrences(of: ",", with: ""))
        }
        return (subscriptions, favorited, views)
    }

    private static func extractDate(from html: String, marker: String) -> Date? {
        guard let raw = SteamHTML.firstMatch(in: html, pattern: "\(marker)\"?\\s*[:=]\\s*\"?(\\d{9,11})", group: 1),
              let seconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
