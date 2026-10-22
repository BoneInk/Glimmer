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
        guard html.utf8.count <= 8 * 1024 * 1024 else { throw SteamHTTPError.structureChanged("作品页面超出解析大小限制。") }
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

        var detail = WorkshopItemDetail(
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
        detail.authors = extractAuthors(from: html)
        let labels = WorkshopPublicHTML.elements(in: html, className: "detailsStatLeft").map { SteamHTML.stripTags($0.body).lowercased() }
        let values = WorkshopPublicHTML.elements(in: html, className: "detailsStatRight").map { SteamHTML.stripTags($0.body) }
        for (label, value) in zip(labels, values) where !value.isEmpty {
            if ["file size", "文件大小"].contains(label) { detail.fileSizeText = value }
            if ["posted", "发布时间", "发布于"].contains(label) { detail.createdText = value }
            if ["updated", "更新时间", "更新于"].contains(label) { detail.updatedText = value }
        }
        return detail
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
        guard let element = WorkshopPublicHTML.elements(in: html, className: "workshopItemDescription").first
            ?? WorkshopPublicHTML.elements(in: html, id: "workshopItemDescription").first else { return nil }
        let text = WorkshopPublicHTML.plainText(element.body)
        return text.isEmpty ? nil : text
    }

    static func extractAuthors(from html: String) -> [WorkshopAuthor] {
        guard let creators = WorkshopPublicHTML.elements(in: html, className: "creatorsBlock").first else { return [] }
        var seen = Set<String>()
        return WorkshopPublicHTML.elements(in: creators.body, className: "friendBlock").prefix(16).compactMap { block in
            guard let anchor = WorkshopPublicHTML.tags(in: block.body, tag: "a").first(where: { WorkshopPublicHTML.hasClass($0, "friendBlockLinkOverlay") }),
                  let href = WorkshopPublicHTML.attribute("href", in: anchor), let url = URL(string: href),
                  let content = WorkshopPublicHTML.elements(in: block.body, className: "friendBlockContent").first else { return nil }
            let namePart = content.body.components(separatedBy: "<br").first ?? content.body
            let name = SteamHTML.stripTags(namePart)
            let account = WorkshopPublicHTML.attribute("data-miniprofile", in: block.opening).flatMap(UInt64.init)
            let image = WorkshopPublicHTML.tags(in: block.body, tag: "img").first
                .flatMap { WorkshopPublicHTML.attribute("src", in: $0) }.flatMap(URL.init(string:))
            guard let author = WorkshopAuthor(profileURL: url, name: name, avatarURL: image, accountID: account),
                  seen.insert(author.id).inserted else { return nil }
            return author
        }
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
        var candidates = WorkshopPublicHTML.tags(in: html, tag: "meta").compactMap { tag -> String? in
            let name = WorkshopPublicHTML.attribute("property", in: tag) ?? WorkshopPublicHTML.attribute("name", in: tag)
            return ["og:image", "twitter:image"].contains(name?.lowercased() ?? "")
                ? WorkshopPublicHTML.attribute("content", in: tag) : nil
        }
        candidates += WorkshopPublicHTML.tags(in: html, tag: "img").compactMap { tag in
            ["previewImage", "enlargedImage"].contains(WorkshopPublicHTML.attribute("id", in: tag) ?? "")
                ? WorkshopPublicHTML.attribute("src", in: tag) : nil
        }
        for raw in candidates {
            guard let url = WorkshopAuthor.imageURL(URL(string: raw)) else { continue }
            let parts = url.path.split(separator: "/")
            // A UGC image needs BOTH its owner/directory and image key. A URL
            // ending at /ugc/<number>/ is a directory, not a preview image.
            if parts.first == "ugc", parts.count < 3 { continue }
            return url
        }
        return nil
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

/// Bounded, data-only parsing of Steam's legacy public creator pages. No HTML or
/// page JavaScript is executed; creator links and image hosts are validated.
enum WorkshopPublicHTML {
    struct Element { let opening: String; let body: String }

    static func attribute(_ name: String, in tag: String) -> String? {
        SteamHTML.firstMatch(in: tag, pattern: "(?:^|\\s)" + NSRegularExpression.escapedPattern(for: name) + "\\s*=\\s*[\"']([^\"']*)[\"']")
            .map(SteamHTML.decodeEntities)
    }
    static func hasClass(_ tag: String, _ name: String) -> Bool {
        attribute("class", in: tag)?.split(whereSeparator: \.isWhitespace).contains(Substring(name)) == true
    }
    static func tags(in html: String, tag: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<" + tag + "\\b[^>]{0,8192}>", options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(2000).compactMap {
            Range($0.range, in: html).map { String(html[$0]) }
        }
    }
    static func elements(in html: String, className: String? = nil, id: String? = nil) -> [Element] {
        guard let regex = try? NSRegularExpression(pattern: "</?div\\b[^>]{0,8192}>", options: [.caseInsensitive]) else { return [] }
        let tags = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var result = [Element](), start: Range<String.Index>?, opening = "", depth = 0
        for match in tags {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            let closing = tag.hasPrefix("</")
            if let current = start {
                depth += closing ? -1 : 1
                if depth == 0 {
                    if html.distance(from: current.upperBound, to: range.lowerBound) <= 1_000_000 {
                        result.append(.init(opening: opening, body: String(html[current.upperBound..<range.lowerBound])))
                    }
                    start = nil
                    if result.count >= 1000 { break }
                }
            } else if !closing, (className.map { hasClass(tag, $0) } ?? false) || (id != nil && attribute("id", in: tag) == id) {
                start = range; opening = tag; depth = 1
            }
        }
        return result
    }
    static func plainText(_ html: String) -> String {
        let breaks = html.replacingOccurrences(of: "(?i)<br\\s*/?>|</?(?:p|div|li|h[1-6])\\b[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return SteamHTML.decodeEntities(breaks).components(separatedBy: .newlines)
            .map(SteamHTML.collapseWhitespace).joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum WorkshopAuthorPageParser {
    static func parse(html: String, author: WorkshopAuthor, page: Int) throws -> WorkshopAuthorWorksPage {
        guard (1...100_000).contains(page), html.utf8.count <= 8 * 1024 * 1024,
              let container = WorkshopPublicHTML.elements(in: html, className: "workshopBrowseItems").first else {
            throw SteamHTTPError.structureChanged("没有找到作者作品列表，作者页面可能不可访问。")
        }
        let paging = WorkshopPublicHTML.elements(in: html, className: "workshopBrowsePagingInfo").first.map { SteamHTML.stripTags($0.body) } ?? ""
        var total = 0
        var first = 0, last = 0
        if let regex = try? NSRegularExpression(pattern: "Showing\\s+([0-9,]+)\\s*[-–]\\s*([0-9,]+)\\s+of\\s+([0-9,]+)\\s+entries", options: [.caseInsensitive]),
           let match = regex.firstMatch(in: paging, range: NSRange(paging.startIndex..., in: paging)) {
            let numbers = (1...3).compactMap { Range(match.range(at: $0), in: paging).flatMap { Int(paging[$0].replacingOccurrences(of: ",", with: "")) } }
            guard numbers.count == 3 else { throw SteamHTTPError.structureChanged("无法读取作者作品页码。") }
            first = numbers[0]; last = numbers[1]; total = numbers[2]
            guard total <= 3_000_000, total >= last, last >= first,
                  (total == 0 && first == 0 && last == 0 && page == 1) || (first == (page - 1) * 30 + 1 && last - first < 30) else {
                throw SteamHTTPError.structureChanged("作者作品页码与请求不一致，请重试。")
            }
        } else if !container.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SteamHTTPError.structureChanged("作者作品列表缺少可验证的分页信息。")
        } else if page != 1 { throw SteamHTTPError.structureChanged("作者作品页码超出范围。") }
        var results = [WorkshopSearchResult](), seen = Set<String>()
        for block in WorkshopPublicHTML.elements(in: container.body, className: "workshopItem") {
            guard let anchor = WorkshopPublicHTML.tags(in: block.body, tag: "a").first(where: { WorkshopPublicHTML.attribute("data-publishedfileid", in: $0) != nil }),
                  let rawID = WorkshopPublicHTML.attribute("data-publishedfileid", in: anchor), let id = WorkshopItemID(rawID),
                  WorkshopPublicHTML.attribute("data-appid", in: anchor) == "431960",
                  let title = WorkshopPublicHTML.elements(in: block.body, className: "workshopItemTitle").first,
                  seen.insert(id.value).inserted else { throw SteamHTTPError.structureChanged("作者作品卡片缺少有效 ID、应用或标题。") }
            let name = SteamHTML.stripTags(title.body)
            guard !name.isEmpty else { throw SteamHTTPError.structureChanged("作者作品没有标题。") }
            let preview = WorkshopPublicHTML.tags(in: block.body, tag: "img").first(where: { WorkshopPublicHTML.hasClass($0, "workshopItemPreviewImage") })
                .flatMap { WorkshopPublicHTML.attribute("src", in: $0) }.flatMap(URL.init(string:))
            let collection = block.body.contains("workshopItemCollection")
            results.append(.init(publishedFileID: id.value, title: name, shortDescription: "", consumerAppID: 431960,
                previewURL: WorkshopAuthor.imageURL(preview), tags: collection ? ["Collection"] : [], childCount: 0, isCollection: collection))
        }
        guard results.count == (total == 0 ? 0 : last - first + 1) else {
            throw SteamHTTPError.structureChanged("作者作品数量与分页信息不一致，未显示不完整的列表。")
        }
        return .init(author: author, page: page, totalCount: total, totalPages: max(1, (total + 29) / 30), results: results)
    }
}
